#!/usr/bin/ruby

#######

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem "liquid"
  gem "typhoeus"
  gem "mimemagic"
end

require "json"
require "yaml"
require "cgi"
require "time"
require "logger"
require "securerandom"
require "shellwords"

$config = YAML.load_file("_config.yml")

$log = Logger.new($config["log_path"]);
$log.level = Logger::DEBUG

$cgi = nil

# Substitution variables made available to the command hooks, seeded with
# every top-level scalar config key so the user can define their own.
# Operations add others (id, url, path) as appropriate.  $written holds the
# list of files an operation wrote or removed, exposed as %{path}.
$vars = $config.reject { |_, val| val.instance_of?(Hash) || val.instance_of?(Array) }

# Config-defined variables are trusted: they may recursively reference one
# another, and their literal text is treated as shell syntax.  Values added
# later by operations (id, url, path) are not trusted and are always escaped.
$trusted = $vars.keys

$written = []

#############################
##
## Utilities
##

# Remove the specified key from the given hash and execute the
# block on the extracted value.
def remove_and_do(hash, key, &block)
  return unless hash.key? key

  block.call(hash.fetch(key))
  hash.delete(key)
end

# Pull headers out of the environment and return as a hash.
def get_headers
  ENV
    .select { |k, _| k.start_with? 'HTTP_' or k == "CONTENT_TYPE" }
    .collect { |key, val| [key.sub(/^HTTP_/, '').downcase, val] }
    .to_h
end

# Return a merged version of the front matter key mappings
def get_mappings(type, categories)
  mappings = $config.dig("front_matter", "all") || {}
  mappings = mappings.merge($config.dig("front_matter", type) || {})

  (categories || []).each do |category|
    mappings = mappings.merge($config.dig("front_matter", "categories", category) || {})
  end

  mappings
end

# Shell-escape a value for safe inclusion as a single command argument.
def escape_value(value)
  value = value.to_s

  value.empty? ? "" : Shellwords.escape(value)
end

# Recursively expand %{...} references in a command hook string.  Variables
# defined in the config ($trusted) may themselves contain references and are
# expanded as trusted shell text, with only their leaf values escaped.  The
# pre-escaped file list (%{path}) and operation-provided values (id, url) are
# always escaped and never expanded further, so client-supplied data cannot
# inject shell syntax.  Cyclic references expand to an empty string.
def expand(text, seen = [])
  text.gsub(/%\{(\w+)\}/) do
    name = Regexp.last_match(1)

    if name == "path"
      $vars["path"]
    elsif !$trusted.include?(name)
      escape_value($vars[name])
    elsif seen.include?(name)
      $log.error("Cyclic substitution variable: #{name}")
      ""
    else
      value = $vars.fetch(name, "").to_s

      value.include?("%{") ? expand(value, seen + [name]) : escape_value(value)
    end
  end
end

#############################
##
## Post listing, retrieval, and management
##

def posts_path
  File.join($config["site_location"], "_posts")
end

def post_path(id)
  File.join(posts_path, id) + ".md"
end

def list_posts(before = nil, after = nil)
  Dir.glob(File.join(posts_path, "*")).sort.reverse.map { |fn| File.basename(fn, ".md") }
end

def read_post(id)
  fm = nil
  content = nil

  File.open(post_path(id)).each do |line|
    if line.start_with? "---"
      if fm.nil?
        fm = line
      else
        content = ""
      end

      next
    end

    if content.nil?
      fm += line
    else
      content += line
    end
  end

  post = {
    :front_matter => YAML.unsafe_load(fm),
    :content => content,
    :slug => id.split("-").last,
    :id => id
  }

  $config["front_matter"]["all"].each do |key, val|
    if val.instance_of?(Symbol)
      case val.id2name
      when "type"
        post[:type] = post[:front_matter][key]
      when "category"
        post[:category] = post[:front_matter][key]
      end
    end
  end

  post
end

def write_post(post)
  path = post_path(post[:id])

  File.open(path, "w") { |file|
    file.write(post[:front_matter].to_yaml)
    file.write("---\n")
    file.write(post[:content])
  }

  $written << path
end

# Convert a post URL back into its corresponding post id.
def url_to_id(url)
  parts = url.sub($config["site_url"], "").split("/").reject { |part| part.empty? }

  parts[0..-2].join("-") + "-" + File.basename(parts.last, ".*")
end

#############################
##
## Argument parsing
##

# Returns the URL parameters encoded as the equivalent JSON body.
def decode_entry_url_params
  message = {
    "type" => "h-entry",
    "properties" => {}
  }

  $cgi.params.each_key do |key|
    message["properties"][key.sub(/\[\]$/, "")] = $cgi.params[key]
  end

  message["properties"].delete("h")

  message
end

# Extract the (possibly array-wrapped) url from a request message.
def message_url(message)
  url = message["url"]

  url.instance_of?(Array) ? url.first : url
end

#############################
##
## Authentication
##

# Normalize an identity url for comparison: drop trailing slashes and case.
def normalize_url(url)
  url.to_s.sub(%r{/+\z}, "").downcase
end

def authenticate(headers)
  if !headers.key? "authorization"
    $log.error("No authorization header provided.");

    return nil
  end

  url = $config["token_endpoint"]
  token = headers["authorization"]

  $log.debug("Sending auth request using #{token} to #{url}")

  response = Typhoeus::Request.get(
    url,
    :headers => {
      :Accept => "application/json",
      :Authorization => token
    }
  )

  if response.success?
    auth_response = JSON.parse(response.body)

    $log.debug(auth_response);

    me = auth_response["me"]

    return auth_response if normalize_url(me) == normalize_url($config["site_url"])

    $log.error("Token identity #{me.inspect} is not authorized for #{$config['site_url']}")
  elsif response.timed_out?
    $log.error("Request timed out.")
  elsif response.code == 0
    $log.error(response.curl_error_message)
  else
    $log.error("HTTP Error: #{response.code}");
  end

  nil
end

# The token scopes accepted for a given operation, or nil if the operation
# needs only a valid token.  Any one of the listed scopes is sufficient.
def required_scopes(operation)
  {
    "create" => ["create", "post"],
    "update" => ["update"],
    "delete" => ["delete"],
    "upload" => ["media"]
  }[operation]
end

# Check whether the token grants any of the accepted scopes.
def scope_granted?(auth, accepted)
  scopes = auth["scope"]
  scopes = scopes.to_s.split unless scopes.instance_of?(Array)

  accepted.any? { |scope| scopes.include?(scope) }
end

#############################
##
## Microsub operations
##

def channels
  [
    { "uid" => "notifications", "name" => "Notifications" },
    { "uid" => $config["feed"]["uid"], "name" => $config["feed"]["name"] }
  ]
end

def query_channels(message)
  print $cgi.header("content-type" => "application/json")
  print ({ "channels" => channels }).to_json
end

def query_timeline(message)
  items = []
  paging = {}
  response = { "items" => items, "paging" => paging }

  ids = list_posts

  start_idx = 0
  end_idx = 5

  if message.key? "before"
    end_idx = ids.index(message["before"]) - 1
    start_idx = end_idx - 5
  end

  if message.key? "after"
    start_idx = ids.index(message["after"]) + 1
    end_idx = start_idx + 5
  end

  start_idx = start_idx.clamp(0, ids.length - 1)
  end_idx = end_idx.clamp(0, ids.length - 1)

  ids[start_idx..end_idx].each do |id|
    item = {}
    post = read_post(id)
    mappings = get_mappings(post[:type], post[:category])

    mappings.each do |key, val|
      if val.instance_of?(Symbol) && post[:front_matter].key?(key)
        item[val.id2name] = post[:front_matter][key]
      end
    end

    item["type"] = "entry"
    item["content"] = { "text" => post[:content] }
    item["uid"] = post[:id]

    items.append(item)
  end

  if start_idx > 0
    paging["before"] = ids[start_idx]
  end

  if end_idx < ids.length - 1
    paging["after"] = ids[end_idx]
  end

  $log.info(response)

  print $cgi.header("content-type" => "application/json")
  print response.to_json
end

def query_categories(message)
  print $cgi.header("content-type" => "application/json")

  File.open($config["categories"]).each do |line|
    print line
  end
end

##
## Micropub query operations
##

def decode_query_url_params
  message = $cgi.params

  keys = ["action", "before", "after", "channel"]

  keys.each do |key|
    if message.fetch(key, "").instance_of?(Array)
      message[key] = message[key].first
    end
  end

  message
end

def decode_upload_params
  { "file" => $cgi.params["file"].first }
end

def decode_params(cgi, body)
  if cgi.params.key?("h")
    decode_entry_url_params
  elsif cgi.params.key?("q") || $cgi.params.key?("action")
    decode_query_url_params
  elsif cgi.params.key?("file")
    decode_upload_params
  else
    body
  end
end

def query_syndicate(message)
  print $cgi.header("content-type" => "application/json")

  # Lillipub does not implement syndication, but advertises the (empty) list
  # so clients see a spec-compliant response.
  print ({ "syndicate-to" => [] }).to_json
end

def query_config(message)
  response = {
    "media-endpoint" => $config["media_endpoint"],
    "syndicate-to" => [],
    # The notifications channel is read-only (a Microsub concept); it is not a
    # valid Micropub publishing target, so it is excluded here.
    "channels" => channels.reject { |channel| channel["uid"] == "notifications" }.map { |channel| channel["name"] },
    "post-types" => [
      {"type" => "note", "name" => "Note"},
      {"type" => "article", "name" => "Article"},
      {"type" => "photo", "name" => "Photo"},
      {"type" => "reply", "name" => "Reply"},
      {"type" => "like", "name" => "Like"},
      {"type" => "repost", "name" => "Repost"},
      {"type" => "bookmark", "name" => "Bookmark"},
      {"type" => "read", "name" => "Read"}
    ]
  }

  print $cgi.header("content-type" => "application/json")
  print response.to_json
end

def query_source(message)
  post = read_post(url_to_id(message_url(message)))
  mappings = get_mappings(post[:type], post[:category])

  properties = {}

  mappings.each do |key, val|
    if val.instance_of?(Symbol) && post[:front_matter].key?(key)
      value = post[:front_matter][key]
      properties[val.id2name] = value.instance_of?(Array) ? value : [value]
    end
  end

  properties["content"] = [post[:content]]

  response = {
    "type" => ["h-entry"],
    "properties" => properties
  }

  print $cgi.header("content-type" => "application/json")
  print response.to_json
end

#############################
##
## Micropub CRUD operations
##

# The properties in the message are a bit... messy.  This method does a bunch
# of work to clean things up a bit so things are neater when we do the
# front matter remapping operation.
def scrub(hash)
  first = lambda { |val|
    if val.instance_of?(Array)
      val.first
    else
      val
    end
  }

  transformers = {
    "type" => first, "name" => first, "summary" => first, "content" => first,
    "bookmark-of" => first, "like-of" => first, "repost-of" => first, "in-reply-to" => first,
    "published" => lambda { |val| Time.parse(first.call(val)) },
    "read-of" => first, "read-status" => first
  }

  hash.each_key do |key|
    if transformers.key? key
      hash[key] = transformers[key].call(hash[key])
    end
  end
end

def normalize_properties(message)
  scrub(message)
  scrub(message["properties"])

  message["properties"]["content"] ||= ""

  if !message["properties"].key?("published")
    message["properties"]["published"] = Time.now
  end

  published = message["properties"]["published"]

  if message["properties"].key? "like-of"
    message["properties"]["type"] = "like"
    message["properties"]["name"] = message["properties"]["like-of"]
  elsif message["properties"].key? "repost-of"
    message["properties"]["type"] = "repost"
    message["properties"]["name"] = message["properties"]["repost-of"]
  elsif message["properties"].key? "bookmark-of"
    message["properties"]["type"] = "bookmark"
    message["properties"]["name"] = message["properties"]["bookmark-of"]
  elsif message["properties"].key? "read-of"
    message["properties"]["type"] = "read"
    message["properties"]["read-status"] = message["properties"]["read-status"]

    readprops = message["properties"]["read-of"]["properties"]
    title = readprops["name"].first

    message["properties"]["title"] = title

    uidparts = readprops.fetch("uid", [""]).first.split(":")

    if uidparts.length > 1
      message["properties"][uidparts[0]] = uidparts[1]
    end

    case message["properties"]["read-status"]
    when "to-read"
      message["properties"]["name"] = "Want to read #{title}"
    when "reading"
      message["properties"]["name"] = "Currently reading #{title}"
    when "finished"
      message["properties"]["name"] = "Finished reading #{title}"
    end
  elsif message["properties"].key? "name"
    message["properties"]["type"] = "article"
  else
    # This is a hack!  For notes we synthesize a name from the content.
    message["properties"]["type"] = "note"

    name = message["properties"]["content"]

    if name.length > 30
      name = name[0..30].gsub(/[^\w]\w+\s*$/, "...")
    end

    message["properties"]["name"] = name
  end

  message["slug"] =
    message["properties"]["name"]
    .gsub(/[^A-Za-z0-9-]+/, '-')
    .gsub(/-*$/, '')
    .downcase

  if message["slug"] == ""
    message["slug"] = Time.now.strftime("%H-%M-%S")
  end

  message["id"] = published.strftime("%Y-%m-%d-") + message["slug"]

  message
end

def process_photos(message, post)
  images = []

  photos = message["properties"]["photo"] || []
  alts = message["properties"]["mp-photo-alt"] || []

  photos.each_with_index do |photo, index|
    file = store_file(photo, post[:id])

    image = { "path" => file[:relative_url] }

    if !(alts[index] || "").empty?
      image["alt"] = alts[index]
    end

    images.push(image)
  end

  images
end

def to_post(message)
  post = {
    :type => message["properties"]["type"],
    :front_matter => {}
  }

  post[:content] = message["properties"]["content"]
  post[:id] = message["id"]
  post[:slug] = message["slug"]

  date = post[:front_matter]["date"] || Time.now

  post[:front_matter]["date"] = date

  get_mappings(post[:type], message["properties"]["category"]).each do |key, val|
    if val.instance_of?(Symbol)
      source_key = val.id2name

      if message["properties"].key?(source_key)
        post[:front_matter][key] =
          if source_key == "photo"
            process_photos(message, post)
          else
            message["properties"][source_key]
          end
      end
    else
      post[:front_matter][key] = val
    end
  end

  $log.info("Post: #{post}")

  post
end

def create(message)
  normalize_properties(message)
  post = to_post(message)
  date = post[:front_matter]["date"]

  url = $config["site_url"] + date.strftime("/%Y/%m/%d/") + post[:slug]

  $log.debug(post)

  print $cgi.header("status" => "201 Created", "Location" => url)
  write_post(post)

  $vars["id"] = post[:id]
  $vars["url"] = url
end

def update(message)
  post = read_post(url_to_id(message_url(message)))
  mappings = get_mappings(post[:type], post[:category])

  # Build a reverse index from Micropub property to front matter key.
  index = {}
  mappings.each do |key, val|
    index[val.id2name] = key if val.instance_of?(Symbol)
  end

  remove_and_do(message, "replace") do |props|
    props.each do |prop, vals|
      if prop == "content"
        post[:content] = vals.first
      elsif index.key? prop
        key = index[prop]
        post[:front_matter][key] =
          post[:front_matter][key].instance_of?(Array) ? vals : vals.first
      end
    end
  end

  remove_and_do(message, "add") do |props|
    props.each do |prop, vals|
      if prop == "content"
        post[:content] += vals.first
      elsif index.key? prop
        key = index[prop]
        existing = post[:front_matter][key] || []
        existing = [existing] unless existing.instance_of?(Array)
        post[:front_matter][key] = existing + vals
      end
    end
  end

  remove_and_do(message, "delete") do |props|
    if props.instance_of?(Array)
      props.each do |prop|
        if prop == "content"
          post[:content] = ""
        elsif index.key? prop
          post[:front_matter].delete(index[prop])
        end
      end
    else
      props.each do |prop, vals|
        next unless index.key? prop

        key = index[prop]
        post[:front_matter][key] = (post[:front_matter][key] || []) - vals
      end
    end
  end

  $log.debug(post)

  write_post(post)

  $vars["id"] = post[:id]
  $vars["url"] = message_url(message)

  print $cgi.header
end

def delete(message)
  path = post_path(url_to_id(message_url(message)))

  File.delete(path) if File.exist?(path)
  $written << path

  $vars["id"] = url_to_id(message_url(message))
  $vars["url"] = message_url(message)

  print $cgi.header
end

#############################
##
## Media endpoint operations
##

def store_file(file, post_id)
  temp = Tempfile.new

  begin
    IO.copy_stream(file, temp)
    temp.close
    temp.open

    mimetype = MimeMagic.by_magic(temp)

    $log.info("Detected mime: #{mimetype.extensions}")

    uuid = SecureRandom.uuid

    media_path = $config.dig("media_paths", mimetype.image? ? "images" : "files")
    filename = "#{uuid}.#{mimetype.extensions.last}"

    path = File.join($config["site_location"], media_path, filename)
    relative_url = "/" + File.join(media_path, filename)
    url = File.join($config["site_url"], relative_url)

    begin
      metadata = YAML.unsafe_load_file($config["media_metadata"]) || []
    rescue
      metadata = []
    end

    record = {
      :date => Time.now,
      :name => filename,
      :path => path,
      :relative_url => relative_url,
      :url => url,
      :post => post_id
    }
    metadata << record

    File.open($config["media_metadata"], "wb") { |f|
      f.puts YAML.dump(metadata)
    }

    IO.copy_stream(temp.path, path)

    $written << path

    record
  ensure
    temp.close
    temp.unlink
  end
end

def upload(message)
  record = store_file(message["file"], nil)

  print $cgi.header("status" => "201 Created", "Location" => record[:url])
end

def query_last(message)
  response = {}
  last = nil

  begin
    metadata = YAML.unsafe_load_file($config["media_metadata"]) || []
    last = metadata.last
  rescue
  end

  if !last.nil? && (Time.now - last[:date]) < 300
    response["url"] = last[:url]
  end

  print $cgi.header("content-type" => "application/json")
  print response.to_json
end

#############################
##
## Entry-point for script
##

headers = get_headers
body = nil

$log.info(headers)
if !headers.key?("content_type") ||
   !(headers["content_type"].start_with?("multipart/form-data") ||
     headers["content_type"].start_with?("application/x-www-form-urlencoded"))
  begin
    stdin = $stdin.read

    if stdin != ""
      body = JSON.parse(stdin)
    end
  rescue JSON::ParserError
    print CGI.new.header("status" => "400 Bad Request");
    exit(0);
  end
end

$cgi = CGI.new

#
# Query types (parameter 'q')
#   syndicate-to
#   config
#   source

message = decode_params($cgi, body)

$log.info("Message: #{message}")

auth = authenticate(headers)

if auth.nil?
  print $cgi.header("status" => "401 Unauthorized");
  exit(0);
end

callbacks = {
  "create" => lambda { create(message) },
  "update" => lambda { update(message) },
  "delete" => lambda { delete(message) },

  "channels" => lambda { query_channels(message) },
  "channel" => lambda { query_channels(message) },
  "timeline" => lambda { query_timeline(message) },
  "category" => lambda { query_categories(message) },

  "syndicate-to" => lambda { query_syndicate(message) },
  "config" => lambda { query_config(message) },
  "source" => lambda { query_source(message) },
  "upload" => lambda { upload(message) },
  "last" => lambda { query_last(message) }
}

operation =
  if $cgi.params.key?("q")
    # For syndicate-to, config, source, etc.

    $cgi.params["q"].first
  elsif $cgi.params.key?("action")
    # For form-encoded update/delete operations

    message["action"]
  elsif message.instance_of?(Hash) && message.key?("action")
    # For JSON-encoded update/delete operations

    message["action"]
  elsif $cgi.params.key?("file")
    # This is a file upload!

    "upload"
  else
    # Default when we get a straight post of content.

    "create"
  end

accepted = required_scopes(operation)

if !accepted.nil? && !scope_granted?(auth, accepted)
  $log.error("Token scope #{auth['scope'].inspect} does not permit '#{operation}'")
  print $cgi.header("status" => "403 Forbidden");
  exit(0);
end

callbacks[operation].call

# Lastly, if a command was registered for this action, invoke it.  The
# command may reference any of the substitution variables (e.g. %{operation},
# %{path}, %{id}, %{url}), where %{path} is the space-separated list of files
# the operation wrote or removed.
cmd = $config.dig("commands", operation) || nil

if !cmd.nil?
  $vars["operation"] = operation

  # Each written file is escaped individually so that multiple files remain
  # separate shell arguments, while spaces or shell metacharacters within
  # any single path (notably ids derived from a client-supplied url) cannot
  # break out of the command.
  $vars["path"] = $written.map { |file| Shellwords.escape(file) }.join(" ")

  cmd = cmd.map { |part| expand(part) }

  system(*cmd, :err => ["err", "w"], :out => ["out", "w"])
end
