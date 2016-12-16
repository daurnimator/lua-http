## http.h2_connection

An HTTP 2 connection can have multiple streams actively transmitting data at once,
hence an *http.h2_connection* acts much like a scheduler.

### `new(socket, conn_type, settings)` <!-- --> {#http.h2_connection.new}


### `h2_connection.version` <!-- --> {#http.h2_connection.version}

Contains the value of the HTTP 2 version number for the connection. Currently will hold the value of `2`.

See [`connection.version`](#connection.version)


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


### `h2_connection:flush(timeout)` <!-- --> {#http.h2_connection:flush}

See [`connection:flush(timeout)`](#connection:flush)


### `h2_connection:shutdown()` <!-- --> {#http.h2_connection:shutdown}

See [`connection:shutdown()`](#connection:shutdown)


### `h2_connection:close()` <!-- --> {#http.h2_connection:close}

See [`connection:close()`](#connection:close)


### `h2_connection:new_stream(id)` <!-- --> {#http.h2_connection:new_stream}

`id` (optional) is the stream id to assign the new stream. For client initiated streams, this will be the next free odd numbered stream.
For server initiated streams, this will be the next free even numbered stream.

See [`connection:new_stream()`](#connection:new_stream) for more information.


### `h2_connection:get_next_incoming_stream(timeout)` <!-- --> {#http.h2_connection:get_next_incoming_stream}

See [`connection:get_next_incoming_stream(timeout)`](#connection:get_next_incoming_stream)


### `h2_connection:onidle(new_handler)` <!-- --> {#http.h2_connection:onidle}

See [`connection:onidle(new_handler)`](#connection:onidle)


### `h2_connection:read_http2_frame(timeout)` <!-- --> {#http.h2_connection:read_http2_frame}


### `h2_connection:write_http2_frame(typ, flags, streamid, payload, timeout)` <!-- --> {#http.h2_connection:write_http2_frame}


### `h2_connection:ping(timeout)` <!-- --> {#http.h2_connection:ping}


### `h2_connection:write_window_update(inc, timeout)` <!-- --> {#http.h2_connection:write_window_update}


### `h2_connection:write_goaway_frame(last_stream_id, err_code, debug_msg, timeout)` <!-- --> {#http.h2_connection:write_goaway_frame}


### `h2_connection:set_peer_settings(peer_settings)` <!-- --> {#http.h2_connection:set_peer_settings}


### `h2_connection:ack_settings()` <!-- --> {#http.h2_connection:ack_settings}


### `h2_connection:settings(tbl, timeout)` <!-- --> {#http.h2_connection:settings}
