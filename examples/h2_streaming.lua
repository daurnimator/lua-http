#!/usr/bin/env lua
--[[
Makes a request to an HTTP2 endpoint that has an infinite length response.

Usage: lua examples/h2_streaming.lua
]]

local request = require "http.request"

-- This endpoint returns a never-ending stream of chunks containing the current time
local req = request.new_from_uri("https://http2.golang.org/clockstream")
local _, stream = assert(req:go())
for chunk in stream:each_chunk() do
	io.write(chunk)
end
