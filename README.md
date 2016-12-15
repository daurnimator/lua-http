# HTTP library for Lua.

## Features

  - Optionally asynchronous (including DNS lookups and TLS)
  - Supports HTTP(S) version 1.0, 1.1 and 2
  - Functionality for both client and server
  - Websockets
  - Compatible with Lua 5.1, 5.2, 5.3 and [LuaJIT](http://luajit.org/)


## Documentation

Can be found at [https://daurnimator.github.io/lua-http/](https://daurnimator.github.io/lua-http/)


## Status

[![Build Status](https://travis-ci.org/daurnimator/lua-http.svg)](https://travis-ci.org/daurnimator/lua-http)
[![Coverage Status](https://coveralls.io/repos/daurnimator/lua-http/badge.svg?branch=master&service=github)](https://coveralls.io/github/daurnimator/lua-http?branch=master)

  - First release impending!


# Installation

It's recommended to install lua-http by using [luarocks](https://luarocks.org/).
This will automatically install run-time lua dependencies for you.

    $ luarocks install --server=http://luarocks.org/dev http

## Dependencies

  - [cqueues](http://25thandclement.com/~william/projects/cqueues.html) >= 20161214
  - [luaossl](http://25thandclement.com/~william/projects/luaossl.html) >= 20161208
  - [basexx](https://github.com/aiq/basexx/) >= 0.2.0
  - [lpeg](http://www.inf.puc-rio.br/~roberto/lpeg/lpeg.html)
  - [lpeg_patterns](https://github.com/daurnimator/lpeg_patterns) >= 0.3
  - [fifo](https://github.com/daurnimator/fifo.lua)

To use gzip compression you need **one** of:

  - [lzlib](https://github.com/LuaDist/lzlib) or [lua-zlib](https://github.com/brimworks/lua-zlib)

If using lua < 5.3 you will need

  - [compat-5.3](https://github.com/keplerproject/lua-compat-5.3) >= 0.3

If using lua 5.1 you will need

  - [luabitop](http://bitop.luajit.org/) (comes [with LuaJIT](http://luajit.org/extensions.html)) or a [backported bit32](https://luarocks.org/modules/siffiejoe/bit32)

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


## Generating documentation

Documentation is written in markdown and intended to be consumed by [pandoc](http://pandoc.org/)

  - To generate self-contained HTML documentation:
    ```
    $ pandoc -t html5 --template=doc/template.html --section-divs --self-contained --toc -c doc/site.css doc/index.md doc/metadata.yaml
    ```

  - To generate a pdf manual:
    ```
    $ pandoc -s -t latex -V documentclass=article -V classoption=oneside -V links-as-notes -V geometry=a4paper,includeheadfoot,margin=2.54cm doc/index.md doc/metadata.yaml -o lua-http.pdf
    ```
