--[[
Verbosely fetches an HTTP resource
If a body is given, use a POST request

Usage: lua examples/simple_request.lua <URI> [<body>]
]]

local uri = assert(arg[1], "URI needed")
local req_body = arg[2]
local req_timeout = 10

local request = require "http.request"

local req = request.new_from_uri(uri)
if req_body then
	req.headers:upsert(":method", "POST")
	req:set_body(req_body)
end

print("# REQUEST")
print("## HEADERS")
for k, v in req.headers:each() do
	print(k, v)
end
print()
if req.body then
	print("## BODY")
	print(req.body)
	print()
end

print("# RESPONSE")
local headers, stream = req:go(req_timeout)
if headers == nil then
	io.stderr:write(tostring(stream), "\n")
	os.exit(1)
end
print("## HEADERS")
for k, v in headers:each() do
	print(k, v)
end
print()
print("## BODY")
local body, err = stream:get_body_as_string()
if not body and err then
	io.stderr:write(tostring(err), "\n")
	os.exit(1)
end
print(body)
print()
