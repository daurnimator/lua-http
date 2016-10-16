--[[
A server that responds with an infinite server-side-events format.
https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#Event_stream_format

Usage: lua examples/server_sent_events.lua [<port>]
]]

local port = arg[1] or 0 -- 0 means pick one at random

local cqueues = require "cqueues"
local http_server = require "http.server"
local http_headers = require "http.headers"

local myserver = http_server.listen {
	host = "localhost";
	port = port;
	onstream = function(myserver, stream) -- luacheck: ignore 212
		-- Read in headers
		local req_headers = assert(stream:get_headers())
		local req_method = req_headers:get ":method"

		-- Build response headers
		local res_headers = http_headers.new()
		res_headers:append(":status", "200")
		res_headers:append("content-type", "text/event-stream")
		res_headers:append("access-control-allow-origin", "*")
		-- Send headers to client; end the stream immediately if this was a HEAD request
		assert(stream:write_headers(res_headers, req_method == "HEAD"))
		if req_method ~= "HEAD" then
			-- Start a loop that sends the current time to the client each second
			while true do
				local msg = string.format("data: The time is now %s.\n\n", os.date())
				assert(stream:write_chunk(msg, false))
				cqueues.sleep(1) -- yield the current thread for a second.
			end
		end
	end;
	onerror = function(myserver, context, op, err, errno) -- luacheck: ignore 212
		if op == "onstream" and err == 32 then return end
		local msg = op .. " on " .. tostring(context) .. " failed"
		if err then
			msg = msg .. ": " .. tostring(err)
		end
		assert(io.stderr:write(msg, "\n"))
	end;
}

-- Manually call :listen() so that we are bound before calling :localname()
assert(myserver:listen())
do
	local bound_port = select(3, myserver:localname())
	assert(io.stderr:write(string.format("Now listening on port %d\n", bound_port)))
end
-- Start the main server loop
assert(myserver:loop())
