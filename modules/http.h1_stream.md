## http.h1_stream

An h1_stream represents an HTTP 1.0 or 1.1 request/response. The module follows the [*stream*](#stream) interface as well as HTTP 1.x specific functions.

The gzip transfer encoding is supported transparently.

### `h1_stream.connection` <!-- --> {#h1_stream.connection}

See [`stream.connection`](#stream.connection)


### `h1_stream:checktls()` <!-- --> {#h1_stream:checktls}

See [`stream:checktls()`](#stream:checktls)


### `h1_stream:localname()` <!-- --> {#h1_stream:localname}

See [`stream:localname()`](#stream:localname)


### `h1_stream:peername()` <!-- --> {#h1_stream:peername}

See [`stream:peername()`](#stream:peername)


### `h1_stream:get_headers(timeout)` <!-- --> {#h1_stream:get_headers}

See [`stream:get_headers(timeout)`](#stream:get_headers)


### `h1_stream:write_headers(headers, end_stream, timeout)` <!-- --> {#h1_stream:write_headers}

See [`stream:write_headers(headers, end_stream, timeout)`](#stream:write_headers)


### `h1_stream:write_continue(timeout)` <!-- --> {#h1_stream:write_continue}

See [`stream:write_continue(timeout)`](#stream:write_continue)


### `h1_stream:get_next_chunk(timeout)` <!-- --> {#h1_stream:get_next_chunk}

See [`stream:get_next_chunk(timeout)`](#stream:get_next_chunk)


### `h1_stream:each_chunk()` <!-- --> {#h1_stream:each_chunk}

See [`stream:each_chunk()`](#stream:each_chunk)


### `h1_stream:get_body_as_string(timeout)` <!-- --> {#h1_stream:get_body_as_string}

See [`stream:get_body_as_string(timeout)`](#stream:get_body_as_string)


### `h1_stream:get_body_chars(n, timeout)` <!-- --> {#h1_stream:get_body_chars}

See [`stream:get_body_chars(n, timeout)`](#stream:get_body_chars)


### `h1_stream:get_body_until(pattern, plain, include_pattern, timeout)` <!-- --> {#h1_stream:get_body_until}

See [`stream:get_body_until(pattern, plain, include_pattern, timeout)`](#stream:get_body_until)


### `h1_stream:save_body_to_file(file, timeout)` <!-- --> {#h1_stream:save_body_to_file}

See [`stream:save_body_to_file(file, timeout)`](#stream:save_body_to_file)


### `h1_stream:get_body_as_file(timeout)` <!-- --> {#h1_stream:get_body_as_file}

See [`stream:get_body_as_file(timeout)`](#stream:get_body_as_file)


### `h1_stream:unget(str)` <!-- --> {#h1_stream:unget}

See [`stream:unget(str)`](#stream:unget)


### `h1_stream:write_chunk(chunk, end_stream, timeout)` <!-- --> {#h1_stream:write_chunk}

See [`stream:write_chunk(chunk, end_stream, timeout)`](#stream:write_chunk)


### `h1_stream:write_body_from_string(str, timeout)` <!-- --> {#h1_stream:write_body_from_string}

See [`stream:write_body_from_string(str, timeout)`](#stream:write_body_from_string)


### `h1_stream:write_body_from_file(file, timeout)` <!-- --> {#h1_stream:write_body_from_file}

See [`stream:write_body_from_file(file, timeout)`](#stream:write_body_from_file)


### `h1_stream:shutdown()` <!-- --> {#h1_stream:shutdown}

See [`stream:shutdown()`](#stream:shutdown)


### `h1_stream:set_state(new)` <!-- --> {#http.h1_stream:set_state}

Sets the state of the stream to `new`. `new` must be one of the following valid states:

  - `"open"`: have sent or received headers; haven't sent body yet
  - `"half closed (local)"`: have sent whole body
  - `"half closed (remote)"`: have received whole body
  - `"closed"`: complete

Not all state transitions are allowed.


### `h1_stream:read_headers(timeout)` <!-- --> {#http.h1_stream:read_headers}

Reads and returns a table containing the request line and all HTTP headers as key value pairs.

This function should rarely be used, you're probably looking for [`:get_headers()`](#h1_stream:get_headers).
