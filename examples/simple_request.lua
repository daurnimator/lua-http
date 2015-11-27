local uri = assert(arg[1], "URI needed")
local req_timeout = 10

local request = require "http.request"

local req = request.new_from_uri(uri)
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
	io.stderr:write(stream, "\n")
	os.exit(1)
end
print("## HEADERS")
for k, v in headers:each() do
	print(k, v)
end
print()
print("## BODY")
local body = stream:get_body_as_string()
print(body)
print()
