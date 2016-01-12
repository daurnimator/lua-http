# Introduction

## Conventions

Operations that may block the current thread take an optional timeout.

HTTP 1 request and status line fields are passed around inside of [headers](#http.headers) objects under keys `":authority"`, `":method"`, `":path"`, `":scheme"` and `":status"` as defined in HTTP 2. As such, they are all kept in string form (important to remember for the `:status` field).

Header fields should always be used with lower case keys.

### Errors

Invalid function parameters will throw a lua error (if validated).

Errors are returned as `nil, error, errno` unless noted otherwise.

Some HTTP 2 operations return/throw special [http 2 error objects](#http.h2_error).


## Terminology

Much lua-http terminology is borrowed from HTTP 2.

A "connection" is an abstraction over the underlying socket.

A "stream" is a request/response on a connection.


## Common use cases

The highest level interface for clients is [`http.request`](#http.request). By constructing a request object from a uri using [`new_from_uri`](#http.request.new_from_uri) and immediately evaluating it, you can easily fetch an HTTP resource.

```lua
local http_request = require "http.request"
local headers, stream = assert(http_request.new_from_uri("http://example.com"):go())
local body = assert(stream:get_body_as_string())
if headers:get ":status" ~= "200" then
	error(body)
end
print(body)
```


## Asynchronous Operation

All lua-http operations include DNS lookup, connection, TLS negotiation, and read/write operations are asynchronous when run inside of a cqueue.
[Cqueues](http://25thandclement.com/~william/projects/cqueues.html) is a lua library that allows for composable event loops.
Cqueues can be integrated with almost any main loop or event library you may encounter (see [here](https://github.com/wahern/cqueues/wiki/Integrations-with-other-main-loops) for more information + samples), and hence lua-http can be asynchronous in any place you write lua!


# Modules

## http.bit

An abstraction layer over the various lua bit libraries.

Results are only consistent between underlying implementations when parameters and results are in the range of `0` to `0x7fffffff`.


### `band(a, b)` {#http.bit.band}

### `bor(a, b)` {#http.bit.bor}

### `bxor(a, b)` {#http.bit.bxor}


### Example {#http.bit-example}

```lua
local bit = require "http.bit"
print(bit.band(1, 3)) --> 1
```


## http.client

Deals with obtaining a connection to an HTTP server.


### `connect(options, timeout)` {#http.client.connect}

Creates a new connection to an HTTP server.
Can try to negotiate HTTP2 if possible, but 

  - `options` is a table containing:

	  - `family` (integer, optional): socket family to use.  
		defaults to `AF_INET`  

	  - `host` (string): host to connect to.  
		may be either a hostname or an ip address  

	  - `port` (string|integer): port to connect to in numeric form  
		e.g. `"80"` or `80`  

	  - `sendname` (string|boolean, optional): the tls SNI host to send  
		defaults to `true`  
		`true` indicates to copy the `host` field  
		`false` disables SNI  

	  - `v6only` (boolean, optional): if the `IPV6_V6ONLY` flag should be set on the underlying socket.  
		defaults to `false`  

	  - `tls` (boolean|userdata, optional): the `SSL_CTX*` to use, or a boolean to indicate the default  
		defaults to `true`  
		`true` indicates to use the default TLS settings, see [`http.tls`](#http.tls) for information.  
		`false` means do not negotiate tls  

	  - `version` (nil|1.0|1.1|2): HTTP version to use.
		  - `nil`: attempts HTTP 2 and falls back to HTTP 1.1
		  - `1.0`
		  - `1.1`
		  - `2`

	  - `h2_settings` (table, optional): HTTP 2 settings to use  
		See [`http.h2_connection`](#http.h2_connection) for details


  - `timeout` (optional) is the maximum amount of time (in seconds) to allow for connection to be established.

	This includes time for DNS lookup, connection, TLS negotiation (if tls enabled) and in the case of HTTP2: settings exchange.


### Example {#http.client-example}

Connect to a local http server running on port 8000

```lua
local http_client = require "http.client"
local myconnection = http_client.connect {
	host = "localhost";
	port = 8000;
	tls = false;
}
```


## http.h1_connection


## http.h1_reason_phrases

A table mapping from status codes (as strings) to reason phrases for HTTP 1.

Unknown status codes return `"Unassigned"`


### Example {#http.h1_reason_phrases-example}

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

### `new_from_uri(uri)` {#http.request.new_from_uri}


## http.server


## http.stream_common


## http.tls


## http.util


## http.zlib

An abstraction layer over the various lua zlib libraries.


### `engine` {#http.zlib.engine}

Currently either [`"lua-zlib"`](https://github.com/brimworks/lua-zlib) or [`"lzlib"`](https://github.com/LuaDist/lzlib)


### `inflate()` {#http.zlib.inflate}

Returns a function that inflates (uncompresses) a zlib stream.

The function takes a string of compressed data and an end of stream flag,
it returns the uncompressed data as a string.
It will throw an error if the stream is invalid


### `deflate()` {#http.zlib.deflate}

Returns a function that deflates (compresses) a zlib stream.

The function takes a string of uncompressed data and an end of stream flag,
it returns the compressed data as a string.


### Example {#http.zlib-example}

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


### `request(url, ex, callback)` {#http.compat.prosody.request}

A few key differences to the prosody `net.http.request`:

  - must be called from within a running cqueue
  - The callback may be called from a different thread in the cqueue
  - The returned object will be a [`http.request`](#http.request) object
	  - This object is passed to the callback on errors and as the 4th argument on success
  - The default user-agent will be from lua-http (rather than `"Prosody XMPP Server"`)
  - lua-http features (such as HTTP2) will be used where possible


### Example {#http.compat.prosody-example}

```lua
local prosody_http = require "http.compat.prosody"
local cqueues = require "cqueues"
local cq = cqueues.new()
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
