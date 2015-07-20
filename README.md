# HTTP library for Lua.

## Features

  - Optionally asynchronous (including DNS lookups and SSL)
  - Compatible with Lua 5.1, 5.2, 5.3 and [LuaJIT](http://luajit.org/)


# Status

This project is a work in progress and not ready for production use.

[![Build Status](https://travis-ci.org/daurnimator/lua-http.svg)](https://travis-ci.org/daurnimator/lua-http)
[![Coverage Status](https://coveralls.io/repos/daurnimator/lua-http/badge.svg?branch=master&service=github)](https://coveralls.io/github/daurnimator/lua-http?branch=master)

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

If using lua 5.1 you will need

  - [luabitop](http://bitop.luajit.org/) or a backported [bit32](https://rocks.moonscript.org/modules/siffiejoe/bit32)

### For running tests

  - [luacheck](https://github.com/mpeterv/luacheck)
  - [busted](http://olivinelabs.com/busted/)
  - [luacov](https://keplerproject.github.io/luacov/)


# Development

## Getting started

  - Clone the repo:
    ```
    $ git clone https://github.com/daurnimator/lua-http.git
    $ cd lua-http
    ```

  - Install dependencies
    ```
    $ luarocks install --only-deps http-scm-0.rockspec
    ```

  - Lint the code (check for common programming errors)
    ```
    $ luacheck .
    ```

  - Run tests and view coverage report ([install tools first](#for-running-tests))
    ```
    $ busted -c
    $ luacov && less luacov.report.out
    ```

  - Install your local copy:
    ```
    $ luarocks make http-scm-0.rockspec
    ```
