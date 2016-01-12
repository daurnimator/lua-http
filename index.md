
---
title: lua-http
subtitle: HTTP library for Lua
...

# Intro


# Modules

## http.bit

An abstraction layer over the various lua bit libraries.

Results are only consistent between underlying implementations in the range of `0` to `0x7fffffff`.

  - `band(a, b)`
  - `bor(a, b)`
  - `bxor(a, b)`

```lua
local bit = require "http.bit"
print(bit.band(1, 3)) --> 1
```

## http.client


## http.h1_connection


## http.h1_reason_phrases

A table mapping from status codes (as strings) to reason phrases for HTTP 1.

Unknown status codes return `"Unassigned"`

```lua
local reason_phrases = require "http.h1_reason_phrases"
print(reason_phrases["200"]) --> "OK"
print(reason_phrases["342"]) --> "Unassigned"
```


## http.h1_stream


## http.h2_connection


## http.h2_error


## http.h2_stream


## http.headers


## http.hpack


## http.request


## http.server


## http.stream_common


## http.tls


## http.util


## http.zlib

An abstraction layer over the various lua zlib libraries.

  - `engine`

    Currently either [`"lua-zlib"`](https://github.com/brimworks/lua-zlib) or [`"lzlib"`](https://github.com/LuaDist/lzlib)

  - `inflate()`

    Returns a function that inflates (uncompresses) a zlib stream.
    The function takes a string of compressed data and an end of stream flag,
    it returns the uncompressed data as a string.
    It will throw an error if the stream is invalid

  - `deflate()`

    Returns a function that deflates (compresses) a zlib stream.
    The function takes a string of uncompressed data and an end of stream flag,
    it returns the compressed data as a string.

```lua
local zlib = require "http.zlib"
local original = "the racecar raced around the racecar track"
local deflate = zlib.deflate()
local compressed = deflate(original, true)
print(#original, #compressed) -- compressed should be smaller
local inflate = zlib.inflate()
local uncompressed = inflate(compressed, true)
assert(original == uncompressed)
```


## http.compat.prosody

Provides usage similar to [prosody's net.http](https://prosody.im/doc/developers/net/http)

  - `request(url, ex, callback)`

    A few key differences to the prosody `net.http.request`:
      - must be called from within a running cqueue
      - The callback may be called from a different thread in the cqueue
      - The returned object will be a [`http.request`](#http.request) object
        - This object is passed to the callback on errors and as the 4th argument on success
      - The default user-agent will be from lua-http (rather than `"Prosody XMPP Server"`)
      - lua-http features (such as HTTP2) will be used where possible

```lua
local cqueues = require "cqueues"
local cq = cqueues.new()
local prosody_http = require "http.compat.prosody"
cq:wrap(function()
	prosody_http.request("http://httpbin.org/ip", {}, function(b, c, r)
		print(c) --> 200
		print(b) --> {"origin": "123.123.123.123"}
	end)
end)
assert(cq:loop())
```


# Links

  - [Github](https://github.com/daurnimator/lua-http)
  - [Issue tracker](https://github.com/daurnimator/lua-http/issues)
