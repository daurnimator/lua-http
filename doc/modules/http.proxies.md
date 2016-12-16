## http.proxies

### `new()` <!-- --> {#http.proxies.new}

Returns an empty 'proxies' object


### `proxies:update(getenv)` <!-- --> {#http.proxies:update}

`getenv` defaults to [`os.getenv`](http://www.lua.org/manual/5.3/manual.html#pdf-os.getenv)

Reads environmental variables that are used to control if requests go through a proxy.

Returns `proxies`.


### `proxies:choose(scheme, host)` <!-- --> {#http.proxies:choose}

Returns the proxy to use for the given `scheme` and `host` as a URI.
