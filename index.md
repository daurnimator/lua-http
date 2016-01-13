# Introduction

lua-http is an HTTP library for Lua, it supports: both client and server operations, both HTTP 1 and HTTP 2.


## Conventions

Operations that may block the current coroutine take an optional timeout.

HTTP 1 request and status line fields are passed around inside of [headers](#http.headers) objects under keys `":authority"`, `":method"`, `":path"`, `":scheme"` and `":status"` as defined in HTTP 2. As such, they are all kept in string form (important to remember for the `:status` field).

Header fields should always be used with lower case keys.

### Errors

Invalid function parameters will throw a lua error (if validated).

Errors are returned as `nil, error, errno` unless noted otherwise.

Some HTTP 2 operations return/throw special [http 2 error objects](#http.h2_error).


## Terminology

Much lua-http terminology is borrowed from HTTP 2.

A "connection" is an abstraction over the underlying socket.
lua-http has two connection types: one for HTTP 1, one for HTTP 2.

A "stream" is a request/response on a connection.
lua-http has two stream types: one for HTTP 1 based streams, and one for HTTP 2 based streams.
They share a lowest common denominator interface, see (#http.stream_common).


## Common use cases

### Retrieving a document

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


### `band(a, b)` <!-- --> {#http.bit.band}

### `bor(a, b)` <!-- --> {#http.bit.bor}

### `bxor(a, b)` <!-- --> {#http.bit.bxor}


### Example {#http.bit-example}

```lua
local bit = require "http.bit"
print(bit.band(1, 3)) --> 1
```


## http.client

Deals with obtaining a connection to an HTTP server.


### `connect(options, timeout)` <!-- --> {#http.client.connect}

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

### `h1_connection:checktls()` <!-- --> {#http.h1_connection:checktls}

### `h1_connection:localname()` <!-- --> {#http.h1_connection:localname}

### `h1_connection:peername()` <!-- --> {#http.h1_connection:peername}

### `h1_connection:clearerr(...)` <!-- --> {#http.h1_connection:clearerr}

### `h1_connection:take_socket()` <!-- --> {#http.h1_connection:take_socket}

### `h1_connection:shutdown(dir)` <!-- --> {#http.h1_connection:shutdown}

### `h1_connection:close()` <!-- --> {#http.h1_connection:close}

### `h1_connection:new_stream()` <!-- --> {#http.h1_connection:new_stream}

### `h1_connection:get_next_incoming_stream(timeout)` <!-- --> {#http.h1_connection:get_next_incoming_stream}

### `h1_connection:read_request_line(timeout)` <!-- --> {#http.h1_connection:read_request_line}

### `h1_connection:read_status_line(timeout)` <!-- --> {#http.h1_connection:read_status_line}

### `h1_connection:read_header(timeout)` <!-- --> {#http.h1_connection:read_header}

### `h1_connection:read_headers_done(timeout)` <!-- --> {#http.h1_connection:read_headers_done}

### `h1_connection:read_body_by_length(len, timeout)` <!-- --> {#http.h1_connection:read_body_by_length}

### `h1_connection:read_body_till_close(timeout)` <!-- --> {#http.h1_connection:read_body_till_close}

### `h1_connection:read_body_chunk(timeout)` <!-- --> {#http.h1_connection:read_body_chunk}

### `h1_connection:write_request_line(method, path, httpversion, timeout)` <!-- --> {#http.h1_connection:write_request_line}

### `h1_connection:write_status_line(httpversion, status_code, reason_phrase, timeout)` <!-- --> {#http.h1_connection:write_status_line}

### `h1_connection:write_header(k, v, timeout)` <!-- --> {#http.h1_connection:write_header}

### `h1_connection:write_headers_done(timeout)` <!-- --> {#http.h1_connection:write_headers_done}

### `h1_connection:write_body_chunk(chunk, chunk_ext, timeout)` <!-- --> {#http.h1_connection:write_body_chunk}

### `h1_connection:write_body_last_chunk(chunk_ext, timeout)` <!-- --> {#http.h1_connection:write_body_last_chunk}

### `h1_connection:write_body_plain(body, timeout)` <!-- --> {#http.h1_connection:write_body_plain}


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

In addition to the functions from [http.stream_common](#http.stream_common),
a `http.h1_stream` has the following methods:

### `h1_stream:set_state(new)` <!-- --> {#http.h1_stream:set_state}

### `h1_stream:read_headers(timeout)` <!-- --> {#http.h1_stream:read_headers}


## http.h2_connection

An HTTP 2 connection can have multiple streams active and transmitting data at once,
hence a `http.h2_connection` acts much like a scheduler.

### `h2_connection:pollfd()` <!-- --> {#http.h2_connection:pollfd}

### `h2_connection:events()` <!-- --> {#http.h2_connection:events}

### `h2_connection:timeout()` <!-- --> {#http.h2_connection:timeout}

### `h2_connection:empty()` <!-- --> {#http.h2_connection:empty}

### `h2_connection:step(timeout)` <!-- --> {#http.h2_connection:step}

### `h2_connection:loop(timeout)` <!-- --> {#http.h2_connection:loop}

### `h2_connection:checktls()` <!-- --> {#http.h2_connection:checktls}

### `h2_connection:localname()` <!-- --> {#http.h2_connection:localname}

### `h2_connection:peername()` <!-- --> {#http.h2_connection:peername}

### `h2_connection:shutdown()` <!-- --> {#http.h2_connection:shutdown}

### `h2_connection:close()` <!-- --> {#http.h2_connection:close}

### `h2_connection:new_stream(id)` <!-- --> {#http.h2_connection:new_stream}

### `h2_connection:get_next_incoming_stream(timeout)` <!-- --> {#http.h2_connection:get_next_incoming_stream}

### `h2_connection:read_http2_frame(timeout)` <!-- --> {#http.h2_connection:read_http2_frame}

### `h2_connection:write_http2_frame(typ, flags, streamid, payload, timeout)` <!-- --> {#http.h2_connection:write_http2_frame}

### `h2_connection:ping(timeout)` <!-- --> {#http.h2_connection:ping}

### `h2_connection:write_window_update(inc, timeout)` <!-- --> {#http.h2_connection:write_window_update}

### `h2_connection:write_goaway_frame(last_stream_id, err_code, debug_msg)` <!-- --> {#http.h2_connection:write_goaway_frame}

### `h2_connection:set_peer_settings(peer_settings)` <!-- --> {#http.h2_connection:set_peer_settings}

### `h2_connection:ack_settings()` <!-- --> {#http.h2_connection:ack_settings}

### `h2_connection:settings(tbl, timeout)` <!-- --> {#http.h2_connection:settings}


## http.h2_error

A type of error object that encapsulates HTTP 2 error information.
A `http.h2_error` object has fields:

  - `name`: The error `name`: a short identifier for this error
  - `code`: The error code
  - `description`: The description of the error code
  - `message`: An error message
  - `traceback`: A traceback taken at the point the error was thrown
  - `stream_error`: A boolean that indicates if this is a stream level or protocol level error


### `errors` <!-- --> {#http.h2_error.errors}

A table containing errors [as defined by the HTTP 2 specification](https://http2.github.io/http2-spec/#iana-errors).
It can be indexed by error name (e.g. `errors.PROTOCOL_ERROR`) or numeric code (e.g. `errors[0x1]`).


### `is(ob)` <!-- --> {#http.h2_error.is}

Returns a boolean indicating if the object `ob` is a `http.h2_error` object


### `h2_error:new(ob)` <!-- --> {#http.h2_error:new}

Creates a new error object from the passed table.
The table should have the form of an error object i.e. with fields `name`, `code`, `message`, `traceback`, etc.

Fields `name`, `code` and `description` are inherited from the parent `h2_error` object if not specified.

`stream_error` defaults to `false.


### `h2_error:traceback(message, stream_error, lvl)` <!-- --> {#http.h2_error:traceback}

Creates a new error object, recording a traceback from the current thread.


### `h2_error:error(message, stream_error, lvl)` <!-- --> {#http.h2_error:error}

Creates and throws a new error.


### `h2_error:assert(cond, ...)` <!-- --> {#http.h2_error:assert}

If `cond` is truthy, returns `cond, ...`

If `cond` is falsy (i.e. `false` or `nil`), throws an error with the first element of `...` as the `message`.


## http.h2_stream

In addition to the functions from [http.stream_common](#http.stream_common),
a `http.h2_stream` has the following methods:

### `h2_stream:set_state(new)` <!-- --> {#http.h2_stream:set_state}

### `h2_stream:reprioritise(child, exclusive)` <!-- --> {#http.h2_stream:reprioritise}

### `h2_stream:write_http2_frame(typ, flags, payload, timeout)` <!-- --> {#http.h2_stream:write_http2_frame}

### `h2_stream:write_data_frame(payload, end_stream, padded, timeout)` <!-- --> {#http.h2_stream:write_data_frame}

### `h2_stream:write_headers_frame(payload, end_stream, end_headers, padded, exclusive, stream_dep, weight, timeout)` <!-- --> {#http.h2_stream:write_headers_frame}

### `h2_stream:write_rst_stream(err_code, timeout)` <!-- --> {#http.h2_stream:write_rst_stream}

### `h2_stream:write_settings_frame(ACK, settings, timeout)` <!-- --> {#http.h2_stream:write_settings_frame}

### `h2_stream:write_ping_frame(ACK, payload, timeout)` <!-- --> {#http.h2_stream:write_ping_frame}

### `h2_stream:write_goaway_frame(last_streamid, err_code, debug_msg, timeout)` <!-- --> {#http.h2_stream:write_goaway_frame}

### `h2_stream:write_window_update_frame(inc, timeout)` <!-- --> {#http.h2_stream:write_window_update_frame}

### `h2_stream:write_window_update(inc)` <!-- --> {#http.h2_stream:write_window_update}

### `h2_stream:write_continuation_frame(payload, end_headers, timeout)` <!-- --> {#http.h2_stream:write_continuation_frame}


## http.headers

An ordered list of header fields.
Each field has a *name*, a *value* and a *never_index* flag that indicates if the header field is potentially sensitive data.

Each headers object has an index by field name to efficiently retrieve values by key. Keep in mind that there can be multiple values for a given field name. (e.g. an HTTP server may send two `Set-Cookie` headers).

### `new()` <!-- --> {#http.headers.new}

Creates and returns a new headers object.


### `headers:len()` <!-- --> {#http.headers:len}

### `headers:clone()` <!-- --> {#http.headers:clone}

### `headers:append(name, value, never_index)` <!-- --> {#http.headers:append}

### `headers:each()` <!-- --> {#http.headers:each}

### `headers:has(name)` <!-- --> {#http.headers:has}

### `headers:delete(name)` <!-- --> {#http.headers:delete}

### `headers:geti(i)` <!-- --> {#http.headers:geti}

### `headers:get_as_sequence(name)` <!-- --> {#http.headers:get_as_sequence}

### `headers:get(name)` <!-- --> {#http.headers:get}

### `headers:get_comma_separated(name)` <!-- --> {#http.headers:get_comma_separated}

### `headers:get_split_as_sequence(name)` <!-- --> {#http.headers:get_split_as_sequence}

### `headers:modifyi(i, value, never_index)` <!-- --> {#http.headers:modifyi}

### `headers:upsert(name, value, never_index)` <!-- --> {#http.headers:upsert}

### `headers:sort()` <!-- --> {#http.headers:sort}


## http.hpack


## http.request

### `new_from_uri(uri)` <!-- --> {#http.request.new_from_uri}

Creates a new `http.request` object from the given URI.

### `request:go(timeout)` <!-- --> {#http.request:timeout}

Performs the request.

The request object is **not** invalidated; and can be reused for a new request.
On success, returns the response [`headers`](#http.headers) and a [`stream`](#http.stream_common).


## http.server


## http.stream_common

Common functions for streams (no matter the underlying protocol version).

All stream types expose the functions:

### `stream:checktls()` <!-- --> {#http.stream_common:checktls}

### `stream:localname()` <!-- --> {#http.stream_common:localname}

### `stream:peername()` <!-- --> {#http.stream_common:peername}

### `stream:get_headers(timeout)` <!-- --> {#http.stream_common:get_headers}

### `stream:write_headers(headers, end_stream, timeout)` <!-- --> {#http.stream_common:write_headers}

### `stream:write_continue(timeout)` <!-- --> {#http.stream_common:write_continue}

### `stream:get_next_chunk(timeout)` <!-- --> {#http.stream_common:get_next_chunk}

### `stream:each_chunk()` <!-- --> {#http.stream_common:each_chunk}

### `stream:get_body_as_string(timeout)` <!-- --> {#http.stream_common:get_body_as_string}

### `stream:save_body_to_file(file, timeout)` <!-- --> {#http.stream_common:save_body_to_file}

### `stream:get_body_as_file(timeout)` <!-- --> {#http.stream_common:get_body_as_file}

### `stream:write_chunk(chunk, end_stream, timeout)` <!-- --> {#http.stream_common:write_chunk}

### `stream:write_body_from_string(str, timeout)` <!-- --> {#http.stream_common:write_body_from_string}

### `stream:write_body_from_file(file, timeout)` <!-- --> {#http.stream_common:write_body_from_file}

### `stream:shutdown()` <!-- --> {#http.stream_common:shutdown}


## http.tls


## http.util


## http.zlib

An abstraction layer over the various lua zlib libraries.


### `engine` <!-- --> {#http.zlib.engine}

Currently either [`"lua-zlib"`](https://github.com/brimworks/lua-zlib) or [`"lzlib"`](https://github.com/LuaDist/lzlib)


### `inflate()` <!-- --> {#http.zlib.inflate}

Returns a function that inflates (uncompresses) a zlib stream.

The function takes a string of compressed data and an end of stream flag,
it returns the uncompressed data as a string.
It will throw an error if the stream is invalid


### `deflate()` <!-- --> {#http.zlib.deflate}

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


### `request(url, ex, callback)` <!-- --> {#http.compat.prosody.request}

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
