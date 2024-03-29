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

$config = YAML.load_file("_config.yml")

$log = Logger.new($config["log_path"]);
$log.level = Logger::DEBUG

$cgi = nil

#############################
##
## Utilities
##

# Remove the specified key from the given hash and execute the
# block on the extracted value.
def remove_and_do(hash, key, &block)
  if hash.key? key
    block.call(hash.fetch(key))
    hash.delete(key)
  end
end

# Pull headers out of the environment and return as a hash.
def get_headers()
  ENV
    .select { |k,v| k.start_with? 'HTTP_' or k == "CONTENT_TYPE" }
    .collect { |key, val| [ key.sub(/^HTTP_/, '').downcase, val ] }
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

#############################
##
## Post listing, retrieval, and management
##

def posts_path
  File.join($config["site_location"], "_posts")
end

def list_posts(before=nil, after=nil)
  Dir.glob(File.join(posts_path, "*")).sort.reverse.map { |fn| File.basename(fn, ".md") }
end

def read_post(id)
  fm = nil
  content = nil

  File.open(File.join(posts_path, id) + ".md").each do |line|
    if line.start_with? "---"
      if fm == nil
        fm = line
      else
        content = ""
      end

      next
    end

    if content == nil
      fm += line
    else
      content += line
    end
  end

  post = {
    :front_matter => YAML.load(fm),
    :content => content,
    :slug => id.split("-").last,
    :id => id
  }

  $config["front_matter"]["all"].each do |key, val|
    if val.instance_of? Symbol and val.id2name == "type"
      post[:type] = post[:front_matter][key]
    end
  end

  post
end

def write_post(post)
  path = File.join($config["site_location"], "_posts", post[:id]) + ".md"

  File.open(path, "w") { |file|
    file.write(post[:front_matter].to_yaml)
    file.write("---\n")
    file.write(post[:content])
  }
end

#############################
##
## Argument parsing
##

# Returns the URL parameters encoded as the equivalent JSON body.
def decode_entry_url_params()
  message = {
    "type" => "h-entry",
    "properties" => {}
  }

  $cgi.params.keys.each do | key |
    message["properties"][key.sub(/\[\]$/, "")] = $cgi.params[key]
  end

  message["properties"].delete("h")

  message
end

#############################
##
## Authentication
##

def authenticate(headers)
  if ! headers.key? "authorization"
    $log.error("No authorization header provided.");

    return false
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

    return true
  elsif response.timed_out?
    $log.error("Request timed out.")
  elsif response.code == 0
    $log.error(response.curl_error_message)
  else
    $log.error("HTTP Error: " + response.code.to_s);
  end

  false
end

#############################
##
## Microsub operations
##

def query_channels(message)
  response = {
    "channels" => [
      {
        "uid" => "notifications",
        "name" => "Notifications"
      },
      {
        "uid" => $config["feed"]["uid"],
        "name" => $config["feed"]["name"]
      }
    ]
  }

  print $cgi.header("content-type" => "application/json")
  print response.to_json
end

def query_timeline(message)
  items = []
  paging = {}
  response = { "items" => items, "paging" => paging }

  ids = list_posts()

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
      if val.instance_of? Symbol and post[:front_matter].key? key
        item[val.id2name] = post[:front_matter][key]
      end
    end

    item["type"] = "entry"
    item["content"] = { "text" => post[:content] }
    item["uid"] = post[:id]

    items.append(item)
  end

  if start_idx > 0
    paging["before"] = id[start_idx]
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

def decode_query_url_params()
  message = $cgi.params

  keys = [ "action", "before", "after", "channel" ]

  keys.each do |key|
    if message.fetch(key, "").class == Array
      message[key] = message[key].first
    end
  end

  message
end

def decode_upload_params()
  file = $cgi.params["file"].first

  message = { "file" => file }

  return message
end

def decode_params(cgi, body)
  if cgi.params.key? "h"
    return decode_entry_url_params()
  elsif cgi.params.key? "q" or $cgi.params.key? "action"
    return decode_query_url_params()
  elsif cgi.params.key? "file"
    return decode_upload_params()
  else
    return body
  end
end

def query_syndicate(message)
end

def query_config(message)
  print $cgi.header("content-type" => "application/json")
  print ({ "media-endpoint" => $config["media_endpoint"] }).to_json
end

def query_source(message)
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
    if val.class == Array
      val.first
    else
      val
    end
  }

  transformers = {
    "type" => first, "name" => first, "summary" => first, "content" => first,
    "bookmark-of" => first, "like-of" => first, "repost-of" => first, "in-reply-to"=> first,
    "published" => lambda { |val| Time.parse(first.call(val)) },
    "read-of" => first, "read-status" => first
  }

  hash.keys.each do |key|
    if transformers.key? key
      hash[key] = transformers[key].call(hash[key])
    end
  end
end

def normalize_properties(message)
  scrub(message)
  scrub(message["properties"])

  message["properties"]["content"] ||= ""

  if ! (message["properties"].key? "published")
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

    if not (alts[index] || "").empty?
      image["alt"] = alts[index]
    end

    images.push(image)
  end

  return images
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
    if val.instance_of? Symbol
      source_key = val.id2name

      if message["properties"].key? source_key
        if (source_key == "photo")
          source_val = process_photos(message, post)
        else
          source_val = message["properties"][source_key]
        end

        post[:front_matter][key] = source_val
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
end

def update(message)
  print $cgi.header
end

def delete(message)
  print $cgi.header
end

#############################
##
## Media endpoint operations
##

def store_file(file, post_id)
  temp = Tempfile.new()

  begin
    IO::copy_stream(file, temp)
    temp.close
    temp.open

    mimetype = MimeMagic.by_magic(temp)

    $log.info("Detected mime: #{mimetype.extensions}")

    uuid = SecureRandom.uuid

    media_path = $config.dig("media_paths", mimetype.image? ? "images" : "files")
    filename = uuid + "." + mimetype.extensions.last

    path = File.join($config["site_location"], media_path, filename)
    relative_url = "/" + File.join(media_path, filename)
    url = File.join($config["site_url"], relative_url)

    begin
      metadata = YAML.load_file($config["media_metadata"]) || []
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

    IO::copy_stream(temp.path, path)

    return record
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
    metadata = YAML.load_file($config["media_metadata"]) || []
    last = metadata.last
  rescue
  end

  if (Time.now - last[:date]) < 300
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
if ! headers.key? "content_type" or
   ! (headers["content_type"].start_with? "multipart/form-data" or
      headers["content_type"].start_with? "application/x-www-form-urlencoded")
  begin
    stdin = STDIN.read

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

if !authenticate(headers)
  print $cgi.header("status" => "401 Unauthorized");
  exit(0);
end

callbacks = {
  "create" => lambda { create(message) },
  "update" => lambda { update(message) },
  "delete" => lambda { delete(message) },

  "channels" => lambda { query_channels(message) },
  "timeline" => lambda { query_timeline(message) },
  "category" => lambda { query_categories(message) },

  "syndicate-to" => lambda { query_syndicate(message) },
  "config" => lambda { query_config(message) },
  "source" => lambda { query_source(message) },
  "upload" => lambda { upload(message) },
  "last" => lambda { query_last(message) }
}

if $cgi.params.key? "q"
  # For syndicate-to, config, source, etc.

  operation = $cgi.params["q"].first
elsif $cgi.params.key? "action"
  # For update/delete operations

  operation = message["action"]
elsif $cgi.params.key? "file"
  # This is a file upload!

  operation = "upload"
else
  # Default when we get a straight post of content.

  operation = "create"
end

callbacks[operation].call()

# Lastly, if a command was registered for this action, invoke it
cmd = $config.dig("commands", operation) || nil

system(*cmd, :err => [ "err", "w" ], :out => [ "out", "w" ]) if (! cmd.nil?)
