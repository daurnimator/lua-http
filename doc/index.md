# Introduction

lua-http is an performant, capable Hyper Text Transfer Protocol (HTTP) and WebSocket (WS) library for Lua 5.1, 5.2, 5.3 and LuaJIT. The software supports x86, x64 and Arm based systems, as well as GNU/Linux, OSX, FreeBSD and others [1]. lua-http can be utilized as a server or client and includes the following features: 

-  HTTP 1 and HTTP 2 as specified by [RFC 7230](https://tools.ietf.org/html/rfc7230) and [RFC 7540](https://tools.ietf.org/html/rfc7540)
-  WebSockets as specified by [RFC 6455](https://tools.ietf.org/html/rfc6455) including ping/pong, binary data transfer and TLS encryption
-  Transport Layer Security (TLS) - lua-http supports HTTPS and WSS via [luaossl](https://github.com/wahern/luaossl).  
-  Fully asynchronous API that does not block the current thread when executing operations that typically block
-  Easy integration into other event-loop based application models

lua-http was written to fill a gap in the Lua ecosystem by providing an HTTP and WebSocket library with the following traits:

- Asynchronous and performant
- Can be used without forcing the developer to follow a specific pattern. Conversely, the library can be adapted to many common patterns. 
- Can be used at a very high level without need to understand the transportation of HTTP data (other than the connection addresses). 
- Provides a rich low level API, if desired, for creating powerful HTTP based tools at the protocol level.

As a result of these design goals, the library is simple and un-obtrusive and can accommodate tens of thousands of connections on commodity hardware. 

lua-http is a flexible HTTP and WebSocket library that allows developers to concentrate on line-of-business features when building Internet enabled applications. If you are looking for a way to streamline development of an internet enabled application, enable HTTP networking in your game, create a new Internet Of Things (IoT) system, or write a performant custom web server for a specific use case, lua-http has the tools you need.

[1] _lua-http is pure lua code and will therefore support any platform that Lua 5.1 or greater supports. Where lua-http can run is mainly limited by where cqueues works (which at the time of writing is BSDs, Linux, OSX, Solaris): if you can port cqueues to it, lua-http should automatically work._


## Common use cases

The following are two simple demonstrations of how the lua-http library can be used: 

### Retrieving A Document

The highest level interface for clients is [*http.request*](#http.request). By constructing a [*request*](#http.request) object from a URI using [`new_from_uri`](#http.request.new_from_uri) and immediately evaluating it, you can easily fetch an HTTP resource.

```lua
local http_request = require "http.request"
local headers, stream = assert(http_request.new_from_uri("http://example.com"):go())
local body = assert(stream:get_body_as_string())
if headers:get ":status" ~= "200" then
	error(body)
end
print(body)
```

### WebSocket Communications

To request information from a WebSocket server, use the `websocket` module to create a new WebSocket client.

```lua
do
	local websocket = require "http.websocket"
	local ws = websocket.new_from_uri("ws://echo.websocket.org")
	assert(ws:connect())

	print(ws:send("Hello from Timbuktu."))

	local out = assert(ws:receive())
	print(out)
end
```

## Asynchronous Operation

lua-http has been written to perform asynchronously so that it can be used in your application, server or game without blocking your main loop. Asynchronous operations are achieved by utilizing cqueues, a Lua/C library that incorporates Lua yielding and kernel level APIs to reduce CPU usage. All lua-http operations including DNS lookup, TLS negotiation and read/write operations will not block the main application thread when run from inside a cqueue or cqueue enabled "container". While sometimes it is necessary to block a routine (yield) and wait for external data, any blocking API calls take an optional timeout to ensure good behavior of networked applications and avoid unresponsive or "dead" routines.

Asynchronous operations are one of the most powerful features of lua-http and require no effort on the developers part. For instance, an HTTP server can be instantiated within any Lua main loop and run alongside application code without adversely affecting the main application process. If other cqueue enabled components are integrated within a cqueue loop, the application is entirely event driven through kernel level polling APIs. 

cqueues can be used in conjunction with lua-http to integrate other features into your lua application and create powerful, performant, web enabled applications. Some of the examples in this guide will use cqueues for simple demonstrations. For more resources about cqueues, please see:

- [The cqueues website](http://25thandclement.com/~william/projects/cqueues.html) for more information about the cqueues library. 

- cqueues examples can be found with the cqueues source code available through [git or archives](http://www.25thandclement.com/~william/projects/cqueues.html#download) or accessed online [here](https://github.com/wahern/cqueues/tree/master/examples). 

- For more information on integrating cqueues with other event loop libraries please see [integration with other event loops](https://github.com/wahern/cqueues/wiki/Integrations-with-other-main-loops).

- For other libraries that use cqueues such as asynchronous APIs for Redis and PostgreSQL, please see [the cqueues wiki entry here](https://github.com/wahern/cqueues/wiki/Libraries-that-use-cqueues).


## Conventions

The following is a list of API conventions and general reference: 

###HTTP 

- HTTP 1 request and status line fields are passed around inside of _[headers](#http.headers)_ objects under keys `":authority"`, `":method"`, `":path"`, `":scheme"` and `":status"` as defined in HTTP 2. As such, they are all kept in string form (important to remember for the `:status` field).

- Header fields should always be used with lower case keys.


### Errors

- Invalid function parameters will throw a lua error (if validated).

- Errors are returned as `nil`, error, errno unless noted otherwise.

- Some HTTP 2 operations return/throw special [http 2 error objects](#http.h2_error).


## Terminology

Much lua-http terminology is borrowed from HTTP 2. 

_[Connection](#connection)_ - An abstraction over an underlying TCP/IP socket. lua-http currently has two connection types: one for HTTP 1, one for HTTP 2.

_[Stream](#stream)_ - A request/response on a connection object. lua-http has two stream types: one for [*HTTP 1 streams*](#http.h1_stream), and one for [*HTTP 2 streams*](#http.h2_stream). They common interfaces are described in [*stream*](#stream) and [*http.stream_common*](#http.stream_common).

_Newline_ - A single carriage return and line feed `"\r\n"`, indicating a blank line


# Interfaces

## connection

lua-http has separate libraries for both HTTP 1 and HTTP 2 type communications. Future protocols will also be supported and exposed as new modules. As HTTP 1 and 2 share common concepts at the connection and stream level, the _[connection](#connection)_ and _[stream](#stream)_ modules have been written to contain common interfaces wherever possible. All _[connection](#connection)_ types expose the following fields:


### `connection.type` <!-- --> {#connection.type}

The mode of use for the connection object. Valid values are:

- `"client"` - Connects to a remote URI
- `"server"` - Listens for connection on a local URI


### `connection.version` <!-- --> {#connection.version}

The HTTP version number of the connection as a number. 


### `connection:connect(timeout)` <!-- --> {#connection:connect}

Completes the connection to the remote server using the address specified, HTTP version and any options specified in the `connection.new` constructor. The `connect` function will yield until the connection attempt finishes (success or failure) or until `timeout` is exceeded. Connecting may include DNS lookups, TLS negotiation and HTTP2 settings exchange. Returns `true` on success. On failure returns `nil` and an error message.


### `connection:checktls()` <!-- --> {#connection:checktls}

Checks the socket for a valid Transport Layer Security connection. Returns the luaossl ssl object if the connection is secured. Returns `nil` and an error message if there is no active TLS session. Please see the [luaossl website](http://25thandclement.com/~william/projects/luaossl.html) for more information about the ssl object.


### `connection:localname()` <!-- --> {#connection:localname}

Returns the connection information for the local socket. Returns address family, IP address and port for an external socket. For Unix domain sockets, the function returns `AF_UNIX` and the path. If the connection object is not connected, returns `AF_UNSPEC` (0). On error, returns `nil` an error message and an error number.


### `connection:peername()` <!-- --> {#connection:peername}

Returns the connection information for the socket *peer* (as in, the next hop). Returns address family, IP address and port for an external socket. For unix sockets, the function returns `AF_UNIX` and the path. If the connection object is not connected, returns `AF_UNSPEC` (0). On error, returns `nil` an error message and an error number.

*Note: If the client is using a proxy, the :peername() will be the proxy, not the remote server connection.* 


### `connection:shutdown()` <!-- --> {#connection:shutdown}

Performs an orderly shutdown of the connection by closing all streams and calls `:shutdown()` on the socket. The connection cannot be re-opened. 


### `connection:close()` <!-- --> {#connection:close}

Closes a connection and releases operating systems resources. Note that close performs a `connection:shutdown()` prior to releasing resources.


### `connection:new_stream()` <!-- --> {#connection:new_stream}

Creates a new [*stream*](#stream) on the connection. Use `:new_stream()` to initiate a new http request. In HTTP 1, a new stream can be used for request/response exchanges. In HTTP 2 a new stream can be used for request/response exchanges, organising stream priorities or to initiate a push promise.


### `connection:get_next_incoming_stream(timeout)` <!-- --> {#connection:get_next_incoming_stream}

Returns the next peer initiated [*stream*](#stream) on the connection. This function can be used to yield and "listen" for incoming HTTP streams. 


## stream

All stream types expose the following fields and functions.
The stream modules also share common functionality available via the [*http.stream_common*](#http.stream_common) module.

### `stream.connection` <!-- --> {#stream.connection}

The underlying [*connection*](#connection) object.


### `stream:get_headers(timeout)` <!-- --> {#stream:get_headers}

Retrieves the next complete headers object (i.e. a block of headers or trailers) from the stream.


### `stream:write_headers(headers, end_stream, timeout)` <!-- --> {#stream:write_headers}

Write the given [*headers*](#http.headers) object to the stream. The function takes a flag indicating if this is the last chunk in the stream, if `true` the stream will be closed. If `timeout` is specified, the stream will wait for the send to complete until `timeout` is exceeded.


### `stream:get_next_chunk(timeout)` <!-- --> {#stream:get_next_chunk}

Returns the next chunk of the http body from the socket, otherwise it yields while waiting for input. This function will yield indefinetly, or until `timeout` is exceeded. If the message is compressed, runs inflate to decompress the data. On error, returns `nil`, an error message and an error number.


### `stream:unget(str)` <!-- --> {#stream:unget}

Places `str` back on the incoming data buffer, allowing it to be returned again on a subsequent command ("un-gets" the data). Returns `true` on success. On failure returns `nil`, error message and an error number.


### `stream:write_chunk(chunk, end_stream, timeout)` <!-- --> {#stream:write_chunk}

Writes the string `chunk` to the stream. If `end_stream` is true, the body will be finalized and the stream will be closed. `write_chunk` yields indefinitely, or until `timeout` is exceded.


### `stream:shutdown()` <!-- --> {#stream:shutdown}

Closes the stream. The resources are released and the stream can no longer be used.


# Modules

## http.bit

An abstraction layer over the various lua bit libraries.

Results are only consistent between underlying implementations when parameters and results are in the range of `0` to `0x7fffffff`.


### `band(a, b)` <!-- --> {#http.bit.band}

Bitwise And operation.

### `bor(a, b)` <!-- --> {#http.bit.bor}

Bitwise Or operation. 

### `bxor(a, b)` <!-- --> {#http.bit.bxor}

Bitwise XOr operation.


### Example {#http.bit-example}

```lua
local bit = require "http.bit"
print(bit.band(1, 3)) --> 1
```


## http.client

Deals with obtaining a connection to an HTTP server.


### `connect(options, timeout)` <!-- --> {#http.client.connect}

This function returns a new connection to an HTTP server. Once a connection has been opened, a stream can be created to start a request/response exchange. Please see [`h1_stream.new_stream`](h1_stream.new_stream) and [`h2_stream.new_stream`](h2_stream.new_stream) for more information about creating requests.

  - `options` is a table containing the options to [`http.client.negotiate`](#http.client.negotiate), plus the following:

	  - `family` (integer, optional): socket family to use.  
		defaults to `AF_INET`  

	  - `host` (string): host to connect to.  
		may be either a hostname or an ip address  

	  - `port` (string|integer): port to connect to in numeric form  
		e.g. `"80"` or `80`  

	  - `path` (string): path to connect to (UNIX sockets)

	  - `sendname` (string|boolean, optional): the [TLS SNI](https://en.wikipedia.org/wiki/Server_Name_Indication) host to send.  
		defaults to `true`  
		  - `true` indicates to copy the `host` field
		  - `false` disables SNI

	  - `v6only` (boolean, optional): if the `IPV6_V6ONLY` flag should be set on the underlying socket.

  - `timeout` (optional) is the maximum amount of time (in seconds) to allow for connection to be established.

	This includes time for DNS lookup, connection, TLS negotiation (if TLS enabled) and in the case of HTTP 2: settings exchange.

#### Example {#http.client.connect-example}

Connect to a local HTTP server running on port 8000

```lua
local http_client = require "http.client"
local myconnection = http_client.connect {
	host = "localhost";
	port = 8000;
	tls = false;
}
```


### `negotiate(socket, options, timeout)` <!-- --> {#http.client.negotiate}

Negotiates the HTTP settings with the remote server. If TLS has been specified, this function instantiates the encryption tunnel. Parameters are as follows:
  
  - `socket` is a cqueues socket object

  - `options` is a table containing:

	  - `tls` (boolean|userdata, optional): the `SSL_CTX*` to use, or a boolean to indicate the default TLS context.  
		defaults to `true`.

		  - `true` indicates to use the default TLS settings, see [*http.tls*](#http.tls) for information.
		  - `false` means do not negotiate TLS

	  - `version` (`nil`|1.0|1.1|2): HTTP version to use.
		  - `nil`: attempts HTTP 2 and falls back to HTTP 1.1
		  - `1.0`
		  - `1.1`
		  - `2`

	  - `h2_settings` (table, optional): HTTP 2 settings to use. See [*http.h2_connection*](#http.h2_connection) for details


## http.h1_connection

The h1_connection module adheres to the [*connection*](#connection) interface and provides HTTP 1 and 1.1 specific operations.  

### `new(socket, conn_type, version)` <!-- --> {#connection.new}

Constructor for a new connection. Takes a socket instance, a connection type string and a numeric HTTP version number. Valid values for the connection type are `"client"` and `"server"`. Valid values for the version number are `1` and `1.1`. On success returns the newly initialized connection object in a non-connected state. On failure returns `nil`, an error message and an error number. 


### `h1_connection.version` <!-- --> {#http.h1_connection.version}

Specifies the HTTP version used for the connection handshake. Valid values are:
- `1.0` 
- `1.1`


### `h1_connection:clearerr(...)` <!-- --> {#http.h1_connection:clearerr}

Clears errors to allow for further read or write operations on the connection. Returns the error number of existing errors. This function is used to recover from known errors.


### `h1_connection:take_socket()` <!-- --> {#http.h1_connection:take_socket}

Used to hand the reference of the connection socket to another object. Resets the socket to defaults and returns the single existing reference of the socket to the calling routine. This function can be used for connection upgrades such as upgrading from HTTP 1 to a WebSocket.


### `h1_connection:flush(...)` <!-- --> {#http.h1_connection:flush}

Flushes all buffered outgoing data on the socket. Returns `true` on success. Returns `false` and the error if the socket fails to flush.


### `h1_connection:read_request_line(timeout)` <!-- --> {#http.h1_connection:read_request_line}

Reads a request line from the socket. Returns the request method, requested path and HTTP version for an incoming request. `:read_request_line()` yields until a `"\r\n"` terminated chunk is received, or `timeout` is exceeded. If the incoming chunk is not a valid HTTP request line, `nil` is returned. On error, returns `nil`, an error message and an error number.


### `h1_connection:read_status_line(timeout)` <!-- --> {#http.h1_connection:read_status_line}

Reads a line of input from the socket. If the input is a valid status line, the HTTP version (1 or 1.1), status code and reason description (if applicable) is returned. `:read_status_line()` yields until a "\r\n" terminated chunk is received, or `timeout` is exceeded. If the socket could not be read, returns `nil`, an error message and an error number.


### `h1_connection:read_header(timeout)` <!-- --> {#http.h1_connection:read_header}

Reads a newline terminated HTTP header from the socket and returns the header key and value. This function will yield until a MIME compliant header item is received or until `timeout` is exceeded. If the header could not be read, the function returns `nil` an error and an error message.


### `h1_connection:read_headers_done(timeout)` <!-- --> {#http.h1_connection:read_headers_done}

Checks for an empty line, which indicates the end of the HTTP headers. Returns `true` if an empty line is received. Any other value is pushed back on the socket receive buffer (unget) and the function returns `false`. This function will yield waiting for input from the socket or until `timeout` is exceeded. Returns `nil`, an error and an error message if the socket cannot be read.


### `h1_connection:read_body_by_length(len, timeout)` <!-- --> {#http.h1_connection:read_body_by_length}

Get `len` number of bytes from the socket. Use a negative number for *up to* that number of bytes. This function will yield and wait on the socket if length of the buffered body is less than `len`. Asserts if len is not a number.


### `h1_connection:read_body_till_close(timeout)` <!-- --> {#http.h1_connection:read_body_till_close}

Reads the entire request body. This function will yield until the body is complete or `timeout` is expired. If the read fails the function returns `nil`, an error message and an error number. 


### `h1_connection:read_body_chunk(timeout)` <!-- --> {#http.h1_connection:read_body_chunk}

Reads the next available line of data from the request and returns the chunk and any chunk extensions. This function will yield until chunk size is received or `timeout` is exceeded. If the chunk size is indicated as `0` then `false` and any chunk extensions are returned. Returns `nil`, an error message and an error number if there was an error reading reading the chunk header or the socket.


### `h1_connection:write_request_line(method, path, httpversion, timeout)` <!-- --> {#http.h1_connection:write_request_line}

Writes the opening HTTP 1.x request line for a new request to the socket buffer. Yields until success or `timeout`. If the write fails, returns `nil`, an error message and an error number. 

*Note the request line will not be flushed to the remote server until* [`write_headers_done`](#http.h1_connection:write_headers_done) *is called.*


### `h1_connection:write_status_line(httpversion, status_code, reason_phrase, timeout)` <!-- --> {#http.h1_connection:write_status_line}

Writes an HTTP status line to the socket buffer. Yields until success or `timeout`. If the write fails, the funtion returns `nil`, an error message and an error number. 

*Note the status line will not be flushed to the remote server until* [`write_headers_done`](#http.h1_connection:write_headers_done) *is called.*


### `h1_connection:write_header(k, v, timeout)` <!-- --> {#http.h1_connection:write_header}

Writes a header item to the socket buffer as a `key:value` string. Yields until success or `timeout`. Returns `nil`, an error message and an error if the write fails. 

*Note the header item will not be flushed to the remote server until* [`write_headers_done`](#http.h1_connection:write_headers_done) *is called.*


### `h1_connection:write_headers_done(timeout)` <!-- --> {#http.h1_connection:write_headers_done}

Terminates a header block by writing a blank line (`"\r\n"`) to the socket. This function will flush all outstanding data in the socket output buffer. Yields until success or `timeout`. Returns `nil`, an error message and an error if the write fails.


### `h1_connection:write_body_chunk(chunk, chunk_ext, timeout)` <!-- --> {#http.h1_connection:write_body_chunk}
 
Writes a chunk of data to the socket. `chunk_ext` must be `nil` as chunk extensions are not supported. Will yield until complete or `timeout` is exceeded. Returns true on success. Returns `nil`, an error message and an error number if the write fails. 

*Note that `chunk` will not be flushed to the remote server until* [`write_body_last_chunk`](#http.h1_connection:write_body_last_chunk) *is called.*


### `h1_connection:write_body_last_chunk(chunk_ext, timeout)` <!-- --> {#http.h1_connection:write_body_last_chunk}

Writes the chunked body terminator `"0\r\n"` to the socket and flushes the socket output buffer. `chunk_ext` must be `nil` as chunk extensions are not supported. Will yield until complete or `timeout` is exceeded. Returns `nil`, an error message and an error number if the write fails.


### `h1_connection:write_body_plain(body, timeout)` <!-- --> {#http.h1_connection:write_body_plain}

Writes the contents of `body` to the socket and flushes the socket output buffer immediately. Yields until success or `timeout` is exceeded. Returns `nil`, an error message and an error number if the write fails.


## http.h1_reason_phrases

A table mapping from status codes (as strings) to reason phrases for HTTP 1. Any unknown status codes return `"Unassigned"`


### Example {#http.h1_reason_phrases-example}

```lua
local reason_phrases = require "http.h1_reason_phrases"
print(reason_phrases["200"]) --> "OK"
print(reason_phrases["342"]) --> "Unassigned"
```


## http.h1_stream

An h1_stream represents an HTTP 1.0 or 1.1 request/response. The module follows the [*stream*](#stream) interface and the methods from [*http.stream_common*](#http.stream_common), as well as the following HTTP 1 specific functions:

### `h1_stream:set_state(new)` <!-- --> {#http.h1_stream:set_state}

Sets h1_stream.state if `new` is one of the following valid states:

```lua
valid_states = {
	["idle"] = 1; -- initial
	["open"] = 2; -- have sent or received headers; haven't sent body yet
	["half closed (local)"] = 3; -- have sent whole body
	["half closed (remote)"] = 3; -- have received whole body
	["closed"] = 4; -- complete
}
  ```
  
Asserts if `new` is not a valid value.


### `h1_stream:read_headers(timeout)` <!-- --> {#http.h1_stream:read_headers}

Returns a table containing the request line and all HTTP headers as key value pairs. 


## http.h2_connection

An HTTP 2 connection can have multiple streams actively transmitting data at once,
hence an *http.h2_connection* acts much like a scheduler.


### `new(socket, conn_type, settings)` <!-- --> {#http.h2_connection.new}


### `h2_connection.version` <!-- --> {#http.h2_connection.version}

Contains the value of the HTTP 2 version number for the connection. Currently will hold the value of `2`


### `h2_connection:pollfd()` <!-- --> {#http.h2_connection:pollfd}


### `h2_connection:events()` <!-- --> {#http.h2_connection:events}


### `h2_connection:timeout()` <!-- --> {#http.h2_connection:timeout}


### `h2_connection:empty()` <!-- --> {#http.h2_connection:empty}


### `h2_connection:step(timeout)` <!-- --> {#http.h2_connection:step}


### `h2_connection:loop(timeout)` <!-- --> {#http.h2_connection:loop}


### `h2_connection:connect(timeout)` <!-- --> {#http.h2_connection:connect}

See [`connection:connect(timeout)`](#connection:connect)


### `h2_connection:checktls()` <!-- --> {#http.h2_connection:checktls}

See [`connection:checktls()`](#connection:checktls)


### `h2_connection:localname()` <!-- --> {#http.h2_connection:localname}

See [`connection:localname()`](#connection:localname)


### `h2_connection:peername()` <!-- --> {#http.h2_connection:peername}

See [`connection:peername()`](#connection:peername)


### `h2_connection:shutdown()` <!-- --> {#http.h2_connection:shutdown}

See [`connection:shutdown()`](#connection:shutdown)


### `h2_connection:close()` <!-- --> {#http.h2_connection:close}

See [`connection:close()`](#connection:close)


### `h2_connection:new_stream(id)` <!-- --> {#http.h2_connection:new_stream}

`id` (optional) is the stream id to assign the new stream.  For client initiated streams, this will be the next free odd numbered stream.  
For server initiated streams, this will be the next free even numbered stream.

See [`connection:new_stream()`](#connection:new_stream) for more information.


### `h2_connection:get_next_incoming_stream(timeout)` <!-- --> {#http.h2_connection:get_next_incoming_stream}

See [`connection:get_next_incoming_stream()`](#connection:get_next_incoming_stream)


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
An `http.h2_error` object has fields:

  - `name`: The error name: a short identifier for this error
  - `code`: The error code
  - `description`: The description of the error code
  - `message`: An error message
  - `traceback`: A traceback taken at the point the error was thrown
  - `stream_error`: A boolean that indicates if this is a stream level or protocol level error


### `errors` <!-- --> {#http.h2_error.errors}

A table containing errors [as defined by the HTTP 2 specification](https://http2.github.io/http2-spec/#iana-errors).
It can be indexed by error name (e.g. `errors.PROTOCOL_ERROR`) or numeric code (e.g. `errors[0x1]`).


### `is(ob)` <!-- --> {#http.h2_error.is}

Returns a boolean indicating if the object `ob` is an `http.h2_error` object


### `h2_error:new(ob)` <!-- --> {#http.h2_error:new}

Creates a new error object from the passed table.
The table should have the form of an error object i.e. with fields `name`, `code`, `message`, `traceback`, etc.

Fields `name`, `code` and `description` are inherited from the parent `h2_error` object if not specified.

`stream_error` defaults to `false`.


### `h2_error:new_traceback(message, stream_error, lvl)` <!-- --> {#http.h2_error:new_traceback}

Creates a new error object, recording a traceback from the current thread.


### `h2_error:error(message, stream_error, lvl)` <!-- --> {#http.h2_error:error}

Creates and throws a new error.


### `h2_error:assert(cond, ...)` <!-- --> {#http.h2_error:assert}

If `cond` is truthy, returns `cond, ...`

If `cond` is falsy (i.e. `false` or `nil`), throws an error with the first element of `...` as the `message`.


## http.h2_stream

In addition to following the [*stream*](#stream) interface and the methods from [http.stream_common](#http.stream_common),
an `http.h2_stream` has the following methods:

### `h2_stream:set_state(new)` <!-- --> {#http.h2_stream:set_state}


### `h2_stream:reprioritise(child, exclusive)` <!-- --> {#http.h2_stream:reprioritise}


### `h2_stream:write_http2_frame(typ, flags, payload, timeout)` <!-- --> {#http.h2_stream:write_http2_frame}


### `h2_stream:write_data_frame(payload, end_stream, padded, timeout)` <!-- --> {#http.h2_stream:write_data_frame}


### `h2_stream:write_headers_frame(payload, end_stream, end_headers, padded, exclusive, stream_dep, weight, timeout)` <!-- --> {#http.h2_stream:write_headers_frame}


### `h2_stream:write_priority_frame(exclusive, stream_dep, weight, timeout)` <!-- --> {#http.h2_stream:write_priority_frame}


### `h2_stream:write_rst_stream(err_code, timeout)` <!-- --> {#http.h2_stream:write_rst_stream}


### `h2_stream:write_settings_frame(ACK, settings, timeout)` <!-- --> {#http.h2_stream:write_settings_frame}


### `h2_stream:write_push_promise_frame(promised_stream_id, payload, end_headers, padded, timeout)` <!-- --> {#http.h2_stream:write_push_promise_frame}


### `h2_stream:push_promise(headers, timeout)` <!-- --> {#http.h2_stream:push_promise}

Pushes a new promise to the client.

Returns the new stream as a [h2_stream](#http.h2_stream).


### `h2_stream:write_ping_frame(ACK, payload, timeout)` <!-- --> {#http.h2_stream:write_ping_frame}


### `h2_stream:write_goaway_frame(last_streamid, err_code, debug_msg, timeout)` <!-- --> {#http.h2_stream:write_goaway_frame}


### `h2_stream:write_window_update_frame(inc, timeout)` <!-- --> {#http.h2_stream:write_window_update_frame}


### `h2_stream:write_window_update(inc)` <!-- --> {#http.h2_stream:write_window_update}


### `h2_stream:read_continuation(timeout)` <!-- --> {#http.h2_stream:read_continuation}

Reads a continuation frame from the underlying connection.
If the next frame is not a continuation frame then returns an error.

On success returns a boolean indicating if this was the last continuation frame and the frame payload.


### `h2_stream:write_continuation_frame(payload, end_headers, timeout)` <!-- --> {#http.h2_stream:write_continuation_frame}


## http.headers

An ordered list of header fields.
Each field has a *name*, a *value* and a *never_index* flag that indicates if the header field is potentially sensitive data.

Each headers object has an index by field name to efficiently retrieve values by key. Keep in mind that there can be multiple values for a given field name. (e.g. an HTTP server may send two `Set-Cookie` headers).

### `new()` <!-- --> {#http.headers.new}

Creates and returns a new headers object.


### `headers:len()` <!-- --> {#http.headers:len}

Returns the number of headers.

Also available as `#headers` in Lua 5.2+.


### `headers:clone()` <!-- --> {#http.headers:clone}

Creates and returns a clone of the headers object.


### `headers:append(name, value, never_index)` <!-- --> {#http.headers:append}

Append a header.

  - `name` is the header field name. Lower case is the convention. It will not be validated at this time.
  - `value` is the header field value. It will not be validated at this time.
  - `never_index` is an optional boolean that indicates if the `value` should be considered secret. Defaults to true for header fields: authorization, proxy-authorization, cookie and set-cookie.


### `headers:each()` <!-- --> {#http.headers:each}

An iterator over all headers that emits `name, value, never_index`.

#### Example

```lua
local http_headers = require "http.headers"
local myheaders = http_headers.new()
myheaders:append(":status", "200")
myheaders:append("set-cookie", "foo=bar")
myheaders:append("connection", "close")
myheaders:append("set-cookie", "baz=qux")
for name, value, never_index in myheaders:each() do
	print(name, value, never_index)
end
--[[ prints:
":status", "200", false
"set-cookie", "foo=bar", true
"connection", "close", false
"set-cookie", "baz=qux", true
]]
```


### `headers:has(name)` <!-- --> {#http.headers:has}

Returns a boolean indicating if the headers object has a field with the given `name`.


### `headers:delete(name)` <!-- --> {#http.headers:delete}

Removes all occurrences of a field name from the headers object.


### `headers:geti(i)` <!-- --> {#http.headers:geti}

Return the `i`-th header as `name, value, never_index`


### `headers:get_as_sequence(name)` <!-- --> {#http.headers:get_as_sequence}

Returns all headers with the given name in a table. The table will contain a field `.n` with the number of elements.

#### Example

```lua
local http_headers = require "http.headers"
local myheaders = http_headers.new()
myheaders:append(":status", "200")
myheaders:append("set-cookie", "foo=bar")
myheaders:append("connection", "close")
myheaders:append("set-cookie", "baz=qux")
local mysequence = myheaders:get_as_sequence("set-cookie")
--[[ mysequence will be:
{n = 2; "foo=bar"; "baz=qux"}
]]
```


### `headers:get(name)` <!-- --> {#http.headers:get}

Returns all headers with the given name as multiple return values.


### `headers:get_comma_separated(name)` <!-- --> {#http.headers:get_comma_separated}

Returns all headers with the given name as items in a comma separated string.


### `headers:modifyi(i, value, never_index)` <!-- --> {#http.headers:modifyi}

Change the `i`-th's header to a new `value` and `never_index`.


### `headers:upsert(name, value, never_index)` <!-- --> {#http.headers:upsert}

If a header with the given `name` already exists, replace it. If not, [`append`](#http.headers:append) it to the list of headers.

Cannot be used when a header `name` already has multiple values.


### `headers:sort()` <!-- --> {#http.headers:sort}

Sort the list of headers by their field name, ordering those starting with `:` first. If `name`s are equal then sort by `value`, then by `never_index`.


### `headers:dump(file, prefix)` <!-- --> {#http.headers:dump}

Print the headers list to the given file, one per line.
If `file` is not given, then print to `stderr`.
`prefix` is prefixed to each line.


## http.hpack

### `new(SETTINGS_HEADER_TABLE_SIZE)` <!-- --> {#http.hpack.new}


### `hpack_context:append_data(val)` <!-- --> {#http.hpack:append_data}


### `hpack_context:render_data()` <!-- --> {#http.hpack:render_data}


### `hpack_context:clear_data()` <!-- --> {#http.hpack:clear_data}


### `hpack_context:evict_from_dynamic_table()` <!-- --> {#http.hpack:evict_from_dynamic_table}


### `hpack_context:dynamic_table_tostring()` <!-- --> {#http.hpack:dynamic_table_tostring}


### `hpack_context:set_max_dynamic_table_size(SETTINGS_HEADER_TABLE_SIZE)` <!-- --> {#http.hpack:set_max_dynamic_table_size}


### `hpack_context:encode_max_size(val)` <!-- --> {#http.hpack:encode_max_size}


### `hpack_context:resize_dynamic_table(new_size)` <!-- --> {#http.hpack:resize_dynamic_table}


### `hpack_context:add_to_dynamic_table(name, value, k)` <!-- --> {#http.hpack:add_to_dynamic_table}


### `hpack_context:dynamic_table_id_to_index(id)` <!-- --> {#http.hpack:dynamic_table_id_to_index}


### `hpack_context:lookup_pair_index(k)` <!-- --> {#http.hpack:lookup_pair_index}


### `hpack_context:lookup_name_index(name)` <!-- --> {#http.hpack:lookup_name_index}


### `hpack_context:lookup_index(index, allow_single)` <!-- --> {#http.hpack:lookup_index}


### `hpack_context:add_header_indexed(name, value, huffman)` <!-- --> {#http.hpack:add_header_indexed}


### `hpack_context:add_header_never_indexed(name, value, huffman)` <!-- --> {#http.hpack:add_header_never_indexed}


### `hpack_context:encode_headers(headers)` <!-- --> {#http.hpack:encode_headers}


### `hpack_context:decode_headers(payload, header_list, pos)` <!-- --> {#http.hpack:decode_headers}


## http.hsts

Data structures useful for HSTS (HTTP Strict Transport Security)

### `new_store()` <!-- --> {#http.hsts.new_store}

Creates and returns a new HSTS store.


### `hsts_store:clone()` <!-- --> {#http.hsts:clone}

Creates and returns a copy of a store.


### `hsts_store:store(host, directives)` <!-- --> {#http.hsts:store}

Add new directives to the store about the given `host`. `directives` should be a table of directives, which *must* include the key `"max-age"`.


### `hsts_store:check(host)` <!-- --> {#http.hsts:check}

Returns a boolean indicating if the given `host` is a known HSTS host.


### `hsts_store:clean()` <!-- --> {#http.hsts:clean}

Removes expired entries from the store.


## http.proxies

### `new()` <!-- --> {#http.proxies.new}

Returns an empty 'proxies' object


### `proxies:update(getenv)` <!-- --> {#http.proxies:update}

`getenv` defaults to [`os.getenv`](http://www.lua.org/manual/5.3/manual.html#pdf-os.getenv)

Reads environmental variables that are used to control if requests go through a proxy.

Returns `proxies`.


### `proxies:choose(scheme, host)` <!-- --> {#http.proxies:choose}

Returns the proxy to use for the given `scheme` and `host` as a URI.


## http.request

The http.request module encapsulates all the functionality required to retrieve an HTTP document from a server. 

### `new_from_uri(uri)` <!-- --> {#http.request.new_from_uri}

Creates a new `http.request` object from the given URI.


### `new_connect(uri, connect_authority)` <!-- --> {#http.request.new_connect}

Creates a new `http.request` object from the given URI that will perform a *CONNECT* request.


### `request.host` <!-- --> {#http.request.host}

The host this request should be sent to.


### `request.port` <!-- --> {#http.request.port}

The port this request should be sent to.


### `request.tls` <!-- --> {#http.request.tls}

A boolean indicating if TLS should be used.


### `request.ctx` <!-- --> {#http.request.ctx}

An alternative `SSL_CTX*` to use.
If not specified, uses the default TLS settings (see [*http.tls*](#http.tls) for information).


### `request.sendname` <!-- --> {#http.request.sendname}

The TLS SNI host name used.


### `request.version` <!-- --> {#http.request.version}

The HTTP version to use; leave as `nil` to auto-select.


### `request.proxy` <!-- --> {#http.request.proxy}

Specifies the a proxy that the request will be made through.
The value should be a URI or `false` to turn off proxying for the request.


### `request.headers` <!-- --> {#http.request.headers}

A [*http.headers*](#http.headers) object of headers that will be sent in the request.


### `request.follow_redirects` <!-- --> {#http.request.follow_redirects}

Boolean indicating if `:go()` should follow redirects.
Defaults to `true`.


### `request.expect_100_timeout` <!-- --> {#http.request.expect_100_timeout}

Number of seconds to wait for a 100 Continue response before proceeding to send a request body.
Defaults to `1`.


### `request.max_redirects` <!-- --> {#http.request.max_redirects}

Maximum number of redirects to follow before giving up.
Defaults to `5`.
Set to `math.huge` to not give up.


### `request.post301` <!-- --> {#http.request.post301}

Respect RFC 2616 Section 10.3.2 and **don't** convert POST requests into body-less GET requests when following a 301 redirect. The non-RFC behaviour is ubiquitous in web browsers and assumed by servers. Modern HTTP endpoints send status code 308 to indicate that they don't want the method to be changed.
Defaults to `false`.


### `request.post302` <!-- --> {#http.request.post302}

Respect RFC 2616 Section 10.3.3 and **don't** convert POST requests into body-less GET requests when following a 302 redirect. The non-RFC behaviour is ubiquitous in web browsers and assumed by servers. Modern HTTP endpoints send status code 307 to indicate that they don't want the method to be changed.
Defaults to `false`.


### `request:clone()` <!-- --> {#http.request:clone}

Creates and returns a clone of the request.

The clone has its own deep copies of the [`.headers`](#http.request.headers) and [`.h2_settings`](#http.request.h2_settings) fields.

The [`.tls`](#http.request.tls) and [`.body`](#http.request.body) fields are shallow copied from the original request.


### `request:handle_redirect(headers)` <!-- --> {#http.request:handle_redirect}

Process a redirect.

`headers` should be response headers for a redirect.

Returns a new `request` object that will fetch from new location.


### `request:to_uri(with_userinfo)` <!-- --> {#http.request:to_uri}

Returns a URI for the request.

If `with_userinfo` is `true` and the request has an `authorization` header (or `proxy-authorization` for a CONNECT request), the returned URI will contain a userinfo component.


### `request:set_body(body)` <!-- --> {#http.request:set_body}

Allows setting a request body. `body` may be a string, function or lua file object.

  - If `body` is a string it will be sent as given.
  - If `body` is a function, it will be called repeatedly like an iterator. It should return chunks of the request body as a string or `nil` if done.
  - If `body` is a lua file object, it will be [`:seek`'d](http://www.lua.org/manual/5.3/manual.html#pdf-file:seek) to the start, then sent as a body. Any errors encountered during file operations **will be thrown**.


### `request:go(timeout)` <!-- --> {#http.request:timeout}

Performs the request.

The request object is **not** invalidated; and can be reused for a new request.
On success, returns the response [*headers*](#http.headers) and a [*stream*](#stream).


## http.server

This interface is **unstable**.

### `listen(options)` <!-- --> {#http.server.connect}


### `server:onerror(new_handler)` <!-- --> {#http.server:onerror}


### `server:listen(timeout)` <!-- --> {#http.server:listen}


### `server:localname()` <!-- --> {#http.server:localname}


### `server:pause()` <!-- --> {#http.server:pause}

Cause the server loop to stop processing new clients until [`:resume`](#http.server:resume) is called.


### `server:resume()` <!-- --> {#http.server:resume}


### `server:close()` <!-- --> {#http.server:close}


### `server:pollfd()` <!-- --> {#http.server:pollfd}


### `server:events()` <!-- --> {#http.server:events}


### `server:timeout()` <!-- --> {#http.server:timeout}


### `server:empty()` <!-- --> {#http.server:empty}


### `server:step()` <!-- --> {#http.server:step}


### `server:loop()` <!-- --> {#http.server:loop}


### `server:add_socket(socket)` <!-- --> {#http.server:add_socket}


## http.socks

Implements a subset of the SOCKS proxy protocol.

### `connect(uri)` <!-- --> {#http.socks.connect}

  - `uri` is a string with the address of the SOCKS server. A scheme of `"socks5"` will resolve hosts locally, a scheme of `"socks5h"` will resolve hosts on the SOCKS server. If the URI has a userinfo component it will be sent to the SOCKS server as a username and password.

Returns a *http.socks* object.


### `fdopen(socket)` <!-- --> {#http.socks.fdopen}

  - `socket` should be a cqueues socket object

Returns a *http.socks* object.


### `socks.needs_resolve` <!-- --> {#http.socks.needs_resolve}

Specifies if the destination host should be resolved locally.


### `socks:clone()` <!-- --> {#http.socks:clone}

Make a clone of a given socks object.


### `socks:add_username_password_auth(username, password)` <!-- --> {#http.socks:add_username_password_auth}

Add username + password authorisation to the set of allowed authorisation methods with the given credentials.


### `socks:negotiate(host, port, timeout)` <!-- --> {#http.socks:negotiate}

Complete the SOCKS connection.

  - `host` (required) a string to pass to the SOCKS server as the host to connect to. Will be resolved locally if [`.needs_resolve`](#http.socks.needs_resolve) is `true`
  - `port` (required) a number to pass to the SOCKS server as the port to connect to


### `socks:close()` <!-- --> {#http.socks:close}


### `socks:take_socket()` <!-- --> {#http.socks:take_socket}

Take possesion of the socket object managed by the http.socks object. Returns the socket (or `nil` if not available).


## http.stream_common

The module `http.stream_common` provides common functions for streams (no matter the underlying protocol version). It exports a table `methods` of functions that build on top of the lower level [*stream*](#stream) interface.

### `stream:checktls()` <!-- --> {#http.stream_common:checktls}

Convenience wrapper equivalent to `stream.connection:checktls()`


### `stream:localname()` <!-- --> {#http.stream_common:localname}

Convenience wrapper equivalent to `stream.connection:localname()`


### `stream:peername()` <!-- --> {#http.stream_common:peername}

Convenience wrapper equivalent to `stream.connection:peername()`


### `stream:write_continue(timeout)` <!-- --> {#http.stream_common:write_continue}

Sends a 100-continue header block.


### `stream:each_chunk()` <!-- --> {#http.stream_common:each_chunk}

Iterator over [`stream:get_next_chunk()`](#stream:get_next_chunk)


### `stream:get_body_as_string(timeout)` <!-- --> {#http.stream_common:get_body_as_string}


### `stream:get_body_chars(n, timeout)` <!-- --> {#http.stream_common:get_body_chars}


### `stream:get_body_until(pattern, plain, include_pattern, timeout)` <!-- --> {#http.stream_common:get_body_until}


### `stream:save_body_to_file(file, timeout)` <!-- --> {#http.stream_common:save_body_to_file}


### `stream:get_body_as_file(timeout)` <!-- --> {#http.stream_common:get_body_as_file}


### `stream:write_body_from_string(str, timeout)` <!-- --> {#http.stream_common:write_body_from_string}


### `stream:write_body_from_file(file, timeout)` <!-- --> {#http.stream_common:write_body_from_file}


## http.tls

### `has_alpn` <!-- --> {#http.tls.has_alpn}

Boolean indicating if ALPN is available in the current environment.

It may be disabled if OpenSSL was compiled without ALPN support, or is an old version.


### `modern_cipher_list` <!-- --> {#http.tls.modern_cipher_list}

The [Mozilla "Modern" cipher list](https://wiki.mozilla.org/Security/Server_Side_TLS#Modern_compatibility) as a colon seperated list, ready to pass to OpenSSL


### `intermediate_cipher_list` <!-- --> {#http.tls.intermediate_cipher_list}

The [Mozilla "Intermediate" cipher list](https://wiki.mozilla.org/Security/Server_Side_TLS#Intermediate_compatibility_.28default.29) as a colon seperated list, ready to pass to OpenSSL


### `banned_ciphers` <!-- --> {#http.tls.banned_ciphers}

A set (table with string keys and values of `true`) of the [ciphers banned in HTTP 2](https://http2.github.io/http2-spec/#BadCipherSuites) where the keys are OpenSSL cipher names.

Ciphers not known by OpenSSL are missing from the set.


### `new_client_context()` <!-- --> {#http.tls.new_client_context}

### `new_server_context()` <!-- --> {#http.tls.new_server_context}


## http.util

### `encodeURI(str)` <!-- --> {#http.util.encodeURI}


### `encodeURIComponent(str)` <!-- --> {#http.util.encodeURIComponent}


### `decodeURI(str)` <!-- --> {#http.util.decodeURI}


### `decodeURIComponent(str)` <!-- --> {#http.util.decodeURIComponent}


### `query_args(str)` <!-- --> {#http.util.query_args}

Returns an iterator over the pairs in `str`

#### Example

```lua
local http_util = require "http.util"
for name, value in http_util.query_args("foo=bar&baz=qux") do
	print(name, value)
end
--[[ prints:
"foo", "bar"
"baz", "qux"
]]
```


### `dict_to_query(dict)` <!-- --> {#http.util.dict_to_query}

Converts a dictionary (table with string keys) with string values to an encoded query string.

#### Example

```lua
local http_util = require "http.util"
print(http_util.dict_to_query({foo = "bar"; baz = "qux"})) --> "baz=qux&foo=bar"
```


### `resolve_relative_path(orig_path, relative_path)` <!-- --> {#http.util.resolve_relative_path}


### `scheme_to_port` <!-- --> {#http.util.scheme_to_port}

Map from schemes (as strings) to default ports (as integers).


### `split_authority(authority, scheme)` <!-- --> {#http.util.split_authority}

Splits an `authority` into host and port components.
If the authority has no port component, will attempt to use the default for the `scheme`.

#### Example

```lua
local http_util = require "http.util"
print(http_util.split_authority("localhost:8000", "http")) --> "localhost", 8000
print(http_util.split_authority("example.com", "https")) --> "localhost", 443
```


### `to_authority(host, port, scheme)` <!-- --> {#http.util.to_authority}

Joins the `host` and `port` to create a valid authority component.
Omits the port if it is the default for the `scheme`.


### `imf_date(time)` <!-- --> {#http.util.imf_date}

Returns the time in HTTP preferred date format (See [RFC 7231 section 7.1.1.1](https://tools.ietf.org/html/rfc7231#section-7.1.1.1))

`time` defaults to the current time


### `maybe_quote(str)` <!-- --> {#http.util.maybe_quote}

  - If `str` is a valid `token`, return it as-is.
  - If `str` would be valid as a `quoted-string`, return the quoted version
  - Otherwise, returns `nil`


## http.version

### `name` <!-- --> {#http.version.name}

`"lua-http"`


### `version` <!-- --> {#http.version.version}

Current version of lua-http as a string.


## http.websocket


### `new_from_uri(uri, protocols)` <!-- --> {#http.websocket.new_from_uri}

Creates a new `http.websocket` object of type `"client"` from the given URI.

  - `protocols` (optional) should be a lua table containing a sequence of protocols to send to the server


### `new_from_stream(stream, headers)` <!-- --> {#http.websocket.new_from_stream}

Attempts to create a new `http.websocket` object of type `"server"` from the given request headers and stream.

  - [`stream`](#http.h1_stream) should be a live HTTP 1 stream of the `"server"` type.
  - [`headers`](#http.headers) should be headers of a suspected websocket upgrade request from an HTTP 1 client.

This function does **not** have side effects, and is hence okay to use tentatively.


### `websocket.close_timeout` <!-- --> {#http.websocket.close_timeout}

Amount of time (in seconds) to wait between sending a close frame and actually closing the connection.
Defaults to `3` seconds.


### `websocket:accept(options, timeout)` <!-- --> {#http.websocket:accept}

Completes negotiation with a websocket client.

  - `options` is a table containing:

	  - `headers` (optional) a [headers](#http.headers) object to use as a prototype for the response headers
	  - `protocols` (optional) should be a lua table containing a sequence of protocols to allow from the client

Usually called after a successful [`new_from_stream`](#http.websocket.new_from_stream)


### `websocket:connect(timeout)` <!-- --> {#http.websocket:connect}

Connect to a websocket server.

Usually called after a successful [`new_from_uri`](#http.websocket.new_from_uri)


### `websocket:receive(timeout)` <!-- --> {#http.websocket:receive}

Reads and returns the next data frame plus its opcode.
Any ping frames received while reading will be responded to.

The opcode `0x1` will be returned as `"text"` and `0x2` will be returned as `"binary"`.


### `websocket:each()` <!-- --> {#http.websocket:each}

Iterator over [`websocket:receive()`](#http.websocket:receive).


### `websocket:send_frame(frame, timeout)` <!-- --> {#http.websocket:send_frame}

Low level function to send a raw frame.


### `websocket:send(data, opcode, timeout)` <!-- --> {#http.websocket:send}

Send the given `data` as a data frame.

  - `data` should be a string
  - `opcode` can be a numeric opcode, `"text"` or `"binary"`. If `nil`, defaults to a text frame


### `websocket:send_ping(data, timeout)` <!-- --> {#http.websocket:send_ping}

Sends a ping frame.

  - `data` is optional


### `websocket:send_pong(data, timeout)` <!-- --> {#http.websocket:send_pong}

Sends a pong frame. Works as a unidirectional keepalive.

  - `data` is optional


### `websocket:close(code, reason, timeout)` <!-- --> {#http.websocket:close}

Closes the websocket connection.

  - `code` defaults to `1000`
  - `reason` is an optional string


### Example

```lua
local websocket = require "http.websocket"
local ws = websocket.new_from_uri("wss://echo.websocket.org")
assert(ws:connect())
assert(ws:send("koo-eee!"))
local data = assert(ws:receive())
assert(data == "koo-eee!")
assert(ws:close())
```


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
local deflater = zlib.deflate()
local compressed = deflater(original, true)
print(#original, #compressed) -- compressed should be smaller
local inflater = zlib.inflate()
local uncompressed = inflater(compressed, true)
assert(original == uncompressed)
```


## http.compat.prosody

Provides usage similar to [prosody's net.http](https://prosody.im/doc/developers/net/http)


### `request(url, ex, callback)` <!-- --> {#http.compat.prosody.request}

A few key differences to the prosody `net.http.request`:

  - must be called from within a running cqueue
  - The callback may be called from a different thread in the cqueue
  - The returned object will be a [*http.request*](#http.request) object
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


## http.compat.socket

Provides compatibility with [luasocket's http.request module](http://w3.impa.br/~diego/software/luasocket/http.html).

Differences:

  - Will automatically be non-blocking when run inside a cqueues managed coroutine
  - lua-http features (such as HTTP2) will be used where possible


### Example {#http.compat.socket-example}

Using the 'simple' interface as part of a normal script:

```lua
local socket_http = require "http.compat.socket"
local body, code = assert(socket_http.request("http://lua.org"))
print(code, #body) --> 200, 2514
```


# Links

  - [Github](https://github.com/daurnimator/lua-http)
  - [Issue tracker](https://github.com/daurnimator/lua-http/issues)
