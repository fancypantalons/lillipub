# Lillipub

A single file CGI script Micropub implementation designed for use with static site generators, particularly Jekyll.

## Basic design

Lillipub is a very simple implementation of a basic Micropub endpoint.  Implemented as a one-file Ruby CGI script, Lillipub writes Jekyll-compatible posts to a configured site directory, and then leaves everything else up to other tools or infrastructure.

Lillipub will likely never support:

- Direct integration with Git or other deployment tools.
- Syndication.

## Features

### Creation of common post types

Lillipub supports specific handling of the following content types:

  - Article
  - Note
  - Reply
  - Bookmark
  - Like
  - Repost
  - Photos
  - Read

### File uploads and media endpoint

Lillipub supports basic multipart form POST file uploads, as well as acting as a standalone media endpoint, with a couple of restrictions:

  - No support for alt text.
  - No support for specifying URLs to externally hosted content.

### Front matter mapping

The main advantage of Lillipub over something like Nanopub is the ability to directly control how the Micropub document properties are mapped to/from the Jekyll front matter.  This allows the site owner to have a great deal of control over how pages are constructed and laid out.

For example, consider the following:

```yaml
front_matter:
  article:
    summary: :summary
  like:
    like_of: :like-of
  repost:
    repost_of: :repost-of
  bookmark:
    bookmark_of: :bookmark-of
  categories:
    tweet:
      syndicate_to: [ twitter ]
  all:
    layout: :type
    title: :name
    author: "Brett Kosinski"
    date: :published
    category: :category
    in_reply_to: :in-reply-to
```

The keys in the `front_matter` map refer to post types, along with an `all` section that applies to all types.

Each key-value pair maps a front matter key to either a Micropub property or a fixed value, where properties are denoted with a leading colon (`:`).

## Installation

As Lillipub is a CGI script, it must be placed in your web server CGI path and made executable.

Lillipub uses an inline bundler configuration, so running it once manually will install all necessary dependencies.

## Configuration

Documentation still TODO.  For now just look at the sample file.

## Acknowledgements

Just a quick shoutout to [Daniel Goldsmith](https://ascraeus.org/) who wrote [Nanopub](https://github.com/dg01d/nanopub).  The general approach of a single-file Micropub CGI script was obviously ripped off from his work, and I also frequently consulted his implementation when building my own.
