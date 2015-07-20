-- This modules implements the socket level functionality needed for a HTTP 1 connection
-- It intentionally does not transform strings
-- e.g. header fields are un-normalised

local monotime = require "cqueues".monotime

local connection_methods = {}
local connection_mt = {
	__index = connection_methods;
}

-- assumes ownership of the socket
local function new_connection(socket, version)
	assert(version == 1 or version == 1.1, "unsupported version")
	local self = setmetatable({
		socket = assert(socket);
		version = version;
	}, connection_mt)
	socket:setmode("b", "bf")
	return self
end

function connection_methods:checktls()
	if self.socket == nil then return nil end
	return self.socket:checktls()
end

function connection_methods:localname()
	if self.socket == nil then return nil end
	return self.socket:localname()
end
function connection_methods:peername()
	if self.socket == nil then return nil end
	return self.socket:peername()
end

function connection_methods:take_socket()
	local s = self.socket
	self.socket = nil
	return s
end

function connection_methods:close()
	local s = self:take_socket()
	if s == nil then return end
	s:shutdown()
	s:close()
end

function connection_methods:flush(...)
	return self.socket:flush(...)
end

function connection_methods:read_request_line(timeout)
	local line, err = self.socket:xread("*L", timeout)
	if line == nil then return nil, err end
	local method, path, httpversion = line:match("^(%w+) (%S+) HTTP/(1%.[01])\r\n$")
	if not method then
		error("invalid request line")
	end
	return method, path, tonumber(httpversion)
end

function connection_methods:read_status_line(timeout)
	local line, err = self.socket:xread("*L", timeout)
	if line == nil then return nil, err end
	local httpversion, status_code, reason_phrase = line:match("^HTTP/(1%.[01]) (%d%d%d) (.*)\r\n$")
	if not httpversion then
		error("invalid status line")
	end
	return tonumber(httpversion), status_code, reason_phrase
end

function connection_methods:read_header(timeout)
	local line, err = self.socket:xread("*h", timeout)
	if line == nil then
		-- Note: the *h read returns *just* nil when data is a non-mime compliant header
		return nil, err
	end
	local key, val = line:match("^([^%s:]+): *(.*)$")
	if not key then
		error("invalid header")
	end
	return key, val
end

function connection_methods:read_headers_done(timeout)
	local crlf, err = self.socket:xread(2, timeout)
	if crlf == nil then
		return nil, err
	elseif crlf ~= "\r\n" then
		error("invalid header: expected CRLF")
	end
	return true
end

function connection_methods:each_header(timeout)
	local deadline = timeout and (monotime()+timeout)
	return function(self) -- luacheck: ignore 432
		local key, val = self:read_header(deadline and (deadline-monotime()))
		if key == nil then
			if val == nil then -- EOH
				local ok, err = self:read_headers_done(deadline and (deadline-monotime()))
				if ok == nil then
					error(err)
				end
				-- Success: End of headers
				return nil
			else
				error(val)
			end
		end
		return key, val
	end, self
end

function connection_methods:read_body_by_length(len, timeout)
	assert(type(len) == "number" and len >= 0)
	return self.socket:xread(len, timeout)
end

function connection_methods:read_body_till_close(timeout)
	return self.socket:xread("*a", timeout)
end

function connection_methods:read_body_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	local chunk_header, err = self.socket:xread("*L", timeout)
	if chunk_header == nil then return nil, err end
	local chunk_size, chunk_ext = chunk_header:match("^(%x+) *(.-)\r\n")
	if chunk_size == nil then
		error("invalid chunk")
	elseif #chunk_size > 8 then
		error("invalid chunk: too large")
	end
	chunk_size = tonumber(chunk_size, 16)
	if chunk_ext == "" then
		chunk_ext = nil
	end
	if chunk_size == 0 then
		-- you MUST read trailers after this!
		return nil, chunk_ext
	else
		local chunk_data, err2 = self.socket:xread(chunk_size, deadline and (deadline-monotime()))
		if chunk_data == nil then
			return nil, err2
		end
		local crlf, err3 = self.socket:xread(2, deadline and (deadline-monotime()))
		if crlf == nil then
			return nil, err3
		elseif crlf ~= "\r\n" then
			error("invalid chunk: expected CRLF")
		end
		return chunk_data, chunk_ext
	end
end

function connection_methods:each_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	return function(self) -- luacheck: ignore 432
		return assert(self:read_body_chunk(deadline and (deadline-monotime())))
	end, self
end

function connection_methods:write_request_line(method, path, httpversion, timeout)
	assert(method:match("^[^ \r\n]+$"))
	assert(path:match("^[^ \r\n]+$"))
	assert(httpversion == 1.0 or httpversion == 1.1)
	local line = string.format("%s %s HTTP/%1.1f\r\n", method, path, httpversion)
	return self.socket:xwrite(line, "f", timeout)
end

function connection_methods:write_status_line(httpversion, status_code, reason_phrase, timeout)
	assert(httpversion == 1.0 or httpversion == 1.1)
	assert(status_code:match("^[1-9]%d%d$"), "invalid status code")
	assert(type(reason_phrase) == "string" and reason_phrase:match("^[^\r\n]*$"), "invalid reason phrase")
	local line = string.format("HTTP/%1.1f %s %s\r\n", httpversion, status_code, reason_phrase)
	return self.socket:xwrite(line, "f", timeout)
end

function connection_methods:write_header(k, v, timeout)
	assert(type(k) == "string" and k:match("^[^:\r\n]+$"), "field name invalid")
	assert(type(v) == "string" and v:match("^[^\r\n]*$") and not v:match("^ "), "field value invalid")
	return self.socket:xwrite(string.format("%s: %s\r\n", k, v), "f", timeout)
end

function connection_methods:write_headers_done(timeout)
	-- flushes write buffer
	return self.socket:xwrite("\r\n", "n", timeout)
end

function connection_methods:write_body_chunk(chunk, chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	if chunk == "" then return true end
	-- flushes write buffer
	return self.socket:xwrite(string.format("%x\r\n%s\r\n", #chunk, chunk), "n", timeout)
end

function connection_methods:write_body_last_chunk(chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	-- no flush; writing trailers (via write_headers_done) will do that
	return self.socket:xwrite("0\r\n", "f", timeout)
end

function connection_methods:write_body_plain(body, timeout)
	-- flushes write buffer
	return self.socket:xwrite(body, "n", timeout)
end

return {
	new = new_connection;
	methods = connection_methods;
	mt = connection_mt;
}
