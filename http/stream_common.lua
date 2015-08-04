-- Methods common to both http 1 and http 2 streams

local http_util = require "http.util"

local CHUNK_SIZE = 2^20 -- write in 1MB chunks

local stream_methods = {}

function stream_methods:checktls()
	return self.connection:checktls()
end

function stream_methods:localname()
	return self.connection:localname()
end

function stream_methods:peername()
	return self.connection:peername()
end

function stream_methods:get_split_authority(timeout)
	local host, port
	local ssl = self:checktls()
	local request_headers, err = self:get_headers(timeout)
	if not request_headers then return nil, err end
	local scheme = request_headers:get(":scheme") or (ssl and "https" or "http")
	if request_headers:has(":authority") then
		host, port = http_util.split_authority(request_headers:get(":authority"), scheme)
	else
		local fam -- luacheck: ignore 231
		fam, host, port = self:localname()
		host = ssl:getHostName() or host
	end
	return host, port
end

-- need helper to discard 'last' argument
-- (which would otherwise end up going in 'timeout')
local function each_chunk_helper(self)
	return self:get_next_chunk()
end
function stream_methods:each_chunk()
	return each_chunk_helper, self
end

function stream_methods:get_body_as_string()
	local body, i = {}, 0
	while true do
		local chunk = self:get_next_chunk()
		if chunk == nil then break end
		i = i + 1
		body[i] = chunk
	end
	return table.concat(body, "", 1, i)
end

function stream_methods:save_body_to_file(file)
	while true do
		local chunk = self:get_next_chunk()
		if chunk == nil then break end
		assert(file:write(chunk))
	end
end

function stream_methods:get_body_as_file()
	local file = assert(io.tmpfile())
	self:save_body_to_file(file)
	assert(file:seek("set"))
	return file
end

function stream_methods:write_body_from_string(str)
	self:write_chunk(str, true)
end

function stream_methods:write_body_from_file(file)
	assert(file:seek("set")) -- this implicity disallows non-seekable streams
	-- Can't use :lines here as in Lua 5.1 it doesn't take a parameter
	while true do
		local chunk = file:read(CHUNK_SIZE)
		if chunk == nil then break end
		self:write_chunk(chunk)
	end
	self:write_chunk("", true)
end

return {
	methods = stream_methods;
}
