#!/usr/bin/ruby

#######

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem "liquid"
  gem "typhoeus"
end

require "json"
require "yaml"
require "cgi"
require "time"
require "logger"

$log = Logger.new("lillipub.log");
$log.level = Logger::DEBUG

#######

#
# Utilities
#

# Remove the specified key from the given hash and execute the
# block on the extracted value.
def remove_and_do(hash, key, &block)
  if hash.key? key
    block.call(hash.fetch(key))
    hash.delete(key)
  end
end

#
# Base request processing methods.
#

# Pull headers out of the environment and return as a hash.
def get_headers()
  ENV
    .select { |k,v| k.start_with? 'HTTP_' or k == "CONTENT_TYPE" }
    .collect { |key, val| [ key.sub(/^HTTP_/, '').downcase, val ] }
    .to_h
end

##
## Operations
##

#
# Argument parsing
#

# Returns the URL parameters encoded as the equivalent JSON body.
def decode_url_params(cgi)
  message = {
    "type" => "h-entry",
    "properties" => {}
  }

  cgi.params.keys.each do | key |
    message["properties"][key.sub(/\[\]$/, "")] = cgi.params[key]
  end

  message["properties"].delete("h")

  message
end

# Checks if the "h" parameter is among the URL params.
#
# If so, parses URL params into the JSON equivalent.
#
# Otherwise parses the PmeOST request body as a JSON object.
def get_post_contents(headers, cgi)
  if ! headers["content_type"].start_with? "multipart/form-data"
    begin
      JSON.parse(STDIN.read)
    rescue JSON::ParserError
      print cgi.header("status" => "400 Bad Request");
      exit(0);
    end
  else
    decode_url_params(cgi);
  end
end

#
# Authentication
#

def authenticate(config, headers)
  return true

  if ! headers.key? "authorization"
    $log.error("No authorization header provided.");

    return false
  end

  url = config["token_endpoint"]
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

#
# Micropub query operations
#

def query_syndicate(config, cgi, message)
end

def query_config(config, cgi, message)
end

def query_source(config, cgi, message)
end

#
# Micropub CRUD operations
#

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
    "mp-slug" => first,
    "published" => lambda { |val| Time.parse(first.call(val)) }
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

  if ! (message["properties"].key? "published")
    message["properties"]["published"] = Time.now
  end

  published = message["properties"]["published"]

  if message["properties"].key? "name"
    message["entry-type"] = "article"
  else
    # This is a hack!  For notes we synthesize a name from the content.
    message["entry-type"] = "note"

    name = message["properties"]["content"]

    if name.length > 30
      name = name[0..30].gsub(/[^\w]\w+\s*$/, "...")
    end

    message["properties"]["name"] = name
  end

  if message.key? "mp-slug"
    remove_and_do(message, "mp-slug") do |val|
      message["slug"] = first(val)
    end
  else
    message["slug"] =
      published.strftime("%Y-%m-%d-") +
      message["properties"]["name"]
        .gsub(/[^A-Za-z0-9-]+/, '-')
        .gsub(/-*$/, '')
        .downcase
  end

  message
end

def to_post(config, message)
  entry = {
    :front_matter => {},
  }

  if message["properties"].key? "name"
    entry[:type] = "article"
  else
    entry[:type] = "note"
  end

  mappings = config["front_matter"]["all"].merge(config["front_matter"][message["entry-type"]])

  mappings.each do |key, val|
    if val.instance_of? Symbol
      k = val.id2name

      if message["properties"].key? k
        entry[:front_matter][key] = message["properties"][k]
      end
    else
      entry[:front_matter][key] = val;
    end
  end

  entry[:content] = message["properties"]["content"]
  entry[:slug] = message["slug"]
  entry[:front_matter]["date"] = entry[:front_matter]["date"].strftime(config["date_format"])

  entry
end

def write_post(config, post)
  path = File.join(config["site_location"], "_posts", post[:slug]) + ".md"

  File.open(path, "w") { |file|
    file.write(post[:front_matter].to_yaml)
    file.write("---\n")
    file.write(post[:content])
  }
end

def create(config, cgi, message)
  normalize_properties(message)

  print cgi.header

  post = to_post(config, message)
  $log.debug(post)
  write_post(config, post)
end

def update(config, cgi, message)
  print cgi.header
  print message["type"]
end

def delete(config, cgi, message)
  print cgi.header
  print message["type"]
end

#######

config = YAML.load_file("_config.yml")
cgi = CGI.new
headers = get_headers

#
# Query types (parameter 'q')
#   syndicate-to
#   config
#   source

message = get_post_contents(headers, cgi);

callbacks = {
  "create" => lambda { create(config, cgi, message) },
  "update" => lambda { update(config, cgi, message) },
  "delete" => lambda { delete(config, cgi, message) },
  "syndicate-to" => lambda { query_syndicate(config, cgi, message) },
  "config" => lambda { query_config(config, cgi, message) },
  "source" => lambda { query_source(config, cgi, message) }
}

if !authenticate(config, headers)
  print cgi.header("status" => "401 Unauthorized");
  exit(0);
end


if cgi.params.key? "q"
  # For syndicate-to, config, source, etc.

  operation = cgi.params["q"].first
elsif message.key? "action"
  # For update/delete operations

  operation = message["action"]
else
  # Default when we get a straight post of content.

  operation = "create"
end

callbacks[operation].call();
