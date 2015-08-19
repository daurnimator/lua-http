-- Methods common to both http 1 and http 2 streams

local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ce = require "cqueues.errno"
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
	local request_headers, err, errno = self:get_headers(timeout)
	if not request_headers then
		return nil, err, errno
	end
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

function stream_methods:get_body_as_string(timeout)
	local deadline = timeout and (monotime()+timeout)
	local body, i = {}, 0
	while true do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				break
			else
				return nil, err, errno
			end
		end
		i = i + 1
		body[i] = chunk
		timeout = deadline and (deadline-monotime())
	end
	return table.concat(body, "", 1, i)
end

function stream_methods:save_body_to_file(file, timeout)
	local deadline = timeout and (monotime()+timeout)
	while true do
		local chunk, err, errno = self:get_next_chunk(timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				break
			else
				return nil, err, errno
			end
		end
		assert(file:write(chunk))
		timeout = deadline and (deadline-monotime())
	end
	return true
end

function stream_methods:get_body_as_file(timeout)
	local file = assert(io.tmpfile())
	local ok, err, errno = self:save_body_to_file(file, timeout)
	if not ok then
		return nil, err, errno
	end
	assert(file:seek("set"))
	return file
end

function stream_methods:write_body_from_string(str, timeout)
	return self:write_chunk(str, true, timeout)
end

function stream_methods:write_body_from_file(file, timeout)
	local deadline = timeout and (monotime()+timeout)
	assert(file:seek("set")) -- this implicity disallows non-seekable streams
	-- Can't use :lines here as in Lua 5.1 it doesn't take a parameter
	while true do
		local chunk, err = file:read(CHUNK_SIZE)
		if chunk == nil then
			if err then
				error(err)
			end
			break
		end
		local ok, err2 = self:write_chunk(chunk, false, deadline and (deadline-monotime()))
		if not ok then
			return nil, err2
		end
	end
	return self:write_chunk("", true, deadline and (deadline-monotime()))
end

return {
	methods = stream_methods;
}
