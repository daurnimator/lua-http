# HTTP library for Lua.

## Features

  - Optionally asynchronous (including DNS lookups and SSL)
  - Compatible with Lua 5.1, 5.2, 5.3 and [LuaJIT](http://luajit.org/)


# Status

This project is a work in progress and not ready for production use.

## Todo

  - [ ] HTTP1.1
  - [ ] [HTTP2](https://http2.github.io/http2-spec/)
	  - [x] [HPACK](https://http2.github.io/http2-spec/compression.html)
  - [ ] Connection pooling
  - [ ] [`socket.http`](http://w3.impa.br/~diego/software/luasocket/http.html) compatibility layer
  - [ ] Prosody [`net.http`](https://prosody.im/doc/developers/net/http) compatibility layer
  - [ ] Handle redirects
  - [ ] Be able to use a HTTP proxy
  - [ ] Compression (e.g. gzip)


# Installation

## Dependencies

  - [cqueues](http://25thandclement.com/~william/projects/cqueues.html)
  - [luaossl](http://25thandclement.com/~william/projects/luaossl.html)

If using lua < 5.3 you will need

  - [compat-5.3](https://github.com/keplerproject/lua-compat-5.3)

### For running tests

  - [busted](http://olivinelabs.com/busted/)
  - [luacov](https://keplerproject.github.io/luacov/)
