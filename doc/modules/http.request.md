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


### `request:set_form_data(dict)` <!-- --> {#http.request:set_form_data}

Turns the request into a POST request with a `"application/x-www-form-urlencoded"` encoded body.

`dict` should be a table with string keys and string values.


### `request:go(timeout)` <!-- --> {#http.request:timeout}

Performs the request.

The request object is **not** invalidated; and can be reused for a new request.
On success, returns the response [*headers*](#http.headers) and a [*stream*](#stream).
