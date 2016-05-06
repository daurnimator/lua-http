-- This module implements the socket level functionality needed for an HTTP 1 connection

local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local h1_stream = require "http.h1_stream"
local new_fifo = require "fifo"

local connection_methods = {}
local connection_mt = {
	__name = "http.h1_connection";
	__index = connection_methods;
}

function connection_mt:__tostring()
	return string.format("http.h1_connection{type=%q;version=%.1f}",
		self.type, self.version)
end

local function onerror(socket, op, why, lvl) -- luacheck: ignore 212
	if why == ce.EPIPE or why == ce.ETIMEDOUT then
		return why
	end
	return string.format("%s: %s", op, ce.strerror(why)), why
end

-- assumes ownership of the socket
local function new_connection(socket, conn_type, version)
	if conn_type ~= "client" and conn_type ~= "server" then
		error('invalid connection type. must be "client" or "server"')
	end
	assert(version == 1 or version == 1.1, "unsupported version")
	local self = setmetatable({
		socket = assert(socket);
		type = conn_type;
		version = version;

		-- for server: streams waiting to go out
		-- for client: streams waiting for a response
		pipeline = new_fifo();
		-- pipeline condition is stored in stream itself

		-- for server: held while request being read
		-- for client: held while writing request
		req_locked = nil;
		-- signaled when unlocked
		req_cond = cc.new();
	}, connection_mt)
	socket:setmode("b", "bf")
	socket:onerror(onerror)
	return self
end

function connection_methods:checktls()
	if self.socket == nil then
		return nil
	end
	return self.socket:checktls()
end

function connection_methods:localname()
	if self.socket == nil then
		return nil
	end
	return self.socket:localname()
end

function connection_methods:peername()
	if self.socket == nil then
		return nil
	end
	return self.socket:peername()
end

function connection_methods:clearerr(...)
	if self.socket == nil then
		return nil
	end
	return self.socket:clearerr(...)
end

function connection_methods:take_socket()
	-- TODO: shutdown streams?
	local s = self.socket
	if s == nil then
		-- already taken
		return nil
	end
	self.socket = nil
	self:shutdown()
	-- Reset socket to some defaults
	s:onerror(nil)
	return s
end

function connection_methods:shutdown(dir)
	while self.pipeline:length() > 0 do
		local stream = self.pipeline:peek()
		stream:shutdown()
	end
	if self.socket then
		self.socket:shutdown(dir)
	end
end

function connection_methods:close()
	self:shutdown()
	if self.socket then
		cqueues.poll()
		cqueues.poll()
		self.socket:close()
	end
end

function connection_methods:new_stream()
	assert(self.type == "client")
	if self.socket == nil or self.socket:eof() then
		return nil, ce.EPIPE
	end
	local stream = h1_stream.new(self)
	return stream
end

-- this function *should never throw*
function connection_methods:get_next_incoming_stream(timeout)
	assert(self.type == "server")
	local deadline = timeout and (monotime()+timeout)
	-- Make sure we don't try and read before the previous request has been fully read
	repeat
		-- Wait until previous requests have been fully read
		if self.req_locked then
			if not self.req_cond:wait(deadline and deadline - monotime()) then
				return nil, ce.ETIMEDOUT
			end
			assert(self.req_locked == nil)
		end
		if self.socket == nil then
			return nil, ce.EPIPE
		end
		-- Wait for at least one byte
		local ok, err, errno = self.socket:fill(1, deadline and deadline-monotime())
		if not ok then
			return nil, err or ce.EPIPE, errno
		end
	until not self.req_locked
	local stream = h1_stream.new(self)
	self.pipeline:push(stream)
	self.req_locked = stream
	return stream
end

-- Primarily used for testing
function connection_methods:flush(...)
	return self.socket:flush(...)
end

function connection_methods:read_request_line(timeout)
	local deadline = timeout and (monotime()+timeout)
	local line, err, errno = self.socket:xread("*L", timeout)
	if line == "\r\n" then
		-- RFC 7230 3.5: a server that is expecting to receive and parse a request-line
		-- SHOULD ignore at least one empty line (CRLF) received prior to the request-line.
		line, err, errno = self.socket:xread("*L", deadline and (deadline-monotime()))
	end
	if line == nil then
		return nil, err or ce.EPIPE, errno
	end
	local method, path, httpversion = line:match("^(%w+) (%S+) HTTP/(1%.[01])\r\n$")
	if not method then
		local ok, errno2 = self.socket:unget(line)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		self.socket:seterror("r", ce.EPIPE)
		return nil, ce.EPIPE
	end
	httpversion = httpversion == "1.0" and 1.0 or 1.1 -- Avoid tonumber() due to locale issues
	return method, path, httpversion
end

function connection_methods:read_status_line(timeout)
	local line, err, errno = self.socket:xread("*L", timeout)
	if line == nil then
		return nil, err or ce.EPIPE, errno
	end
	local httpversion, status_code, reason_phrase = line:match("^HTTP/(1%.[01]) (%d%d%d) (.*)\r\n$")
	if not httpversion then
		local ok, errno2 = self.socket:unget(line)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		self.socket:seterror("r", ce.EPIPE)
		return nil, ce.EPIPE
	end
	httpversion = httpversion == "1.0" and 1.0 or 1.1 -- Avoid tonumber() due to locale issues
	return httpversion, status_code, reason_phrase
end

function connection_methods:read_header(timeout)
	local line, err, errno = self.socket:xread("*h", timeout)
	if line == nil then
		-- Note: the *h read returns *just* nil when data is a non-mime compliant header
		return nil, err or ce.EPIPE, errno
	end
	-- header fields can have optional surrounding whitespace
	local key, val = line:match("^([^%s:]+):[ \t]*(.-)[ \t]*$")
	-- don't need to validate, the *h read mode ensures a valid header
	return key, val
end

function connection_methods:read_headers_done(timeout)
	local crlf, err, errno = self.socket:xread(2, timeout)
	if crlf == "\r\n" then
		return true
	elseif crlf == nil then
		return nil, err or ce.EPIPE, errno
	else
		local ok, errno2 = self.socket:unget(crlf)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		self.socket:seterror("r", ce.EPIPE)
		return nil, ce.EPIPE
	end
end

-- pass a negative length for *up to* that number of bytes
function connection_methods:read_body_by_length(len, timeout)
	assert(type(len) == "number")
	local ok, err, errno = self.socket:xread(len, timeout)
	if ok == nil then
		return nil, err or ce.EPIPE, errno
	end
	return ok
end

function connection_methods:read_body_till_close(timeout)
	local ok, err, errno = self.socket:xread("*a", timeout)
	if ok == nil then
		return nil, err or ce.EPIPE, errno
	end
	return ok
end

function connection_methods:read_body_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	local chunk_header, err, errno = self.socket:xread("*L", timeout)
	if chunk_header == nil then
		return nil, err or ce.EPIPE, errno
	end
	local chunk_size, chunk_ext = chunk_header:match("^(%x+) *(.-)\r\n")
	if chunk_size == nil then
		local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
		if not unget_ok1 then
			return nil, onerror(self.socket, "unget", unget_errno1)
		end
		self.socket:seterror("r", ce.EPIPE)
		return nil, ce.EPIPE
	elseif #chunk_size > 8 then
		self.socket:seterror("r", ce.E2BIG)
		return nil, "invalid chunk: too large", ce.E2BIG
	end
	chunk_size = tonumber(chunk_size, 16)
	if chunk_ext == "" then
		chunk_ext = nil
	end
	if chunk_size == 0 then
		-- you MUST read trailers after this!
		return false, chunk_ext
	else
		local chunk_data, err3, errno3 = self.socket:xread(chunk_size, deadline and (deadline-monotime()))
		if chunk_data == nil then
			local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
			if not unget_ok1 then
				return nil, onerror(self.socket, "unget", unget_errno1)
			end
			self.socket:seterror("r", ce.EPIPE)
			return nil, err3 or ce.EPIPE, errno3
		end
		local crlf, err4, errno4 = self.socket:xread(2, deadline and (deadline-monotime()))
		if crlf == "\r\n" then
			-- Success!
			return chunk_data, chunk_ext
		elseif crlf ~= nil then
			local unget_ok3, unget_errno3 = self.socket:unget(crlf)
			if not unget_ok3 then
				return nil, onerror(self.socket, "unget", unget_errno3)
			end
		end
		local unget_ok2, unget_errno2 = self.socket:unget(chunk_data)
		if not unget_ok2 then
			return nil, onerror(self.socket, "unget", unget_errno2)
		end
		local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
		if not unget_ok1 then
			return nil, onerror(self.socket, "unget", unget_errno1)
		end
		self.socket:seterror("r", ce.EPIPE)
		return nil, err4 or ce.EPIPE, errno4
	end
end

function connection_methods:write_request_line(method, path, httpversion, timeout)
	assert(method:match("^[^ \r\n]+$"))
	assert(path:match("^[^ \r\n]+$"))
	assert(httpversion == 1.0 or httpversion == 1.1)
	local line = string.format("%s %s HTTP/%1.1f\r\n", method, path, httpversion)
	local ok, err, errno = self.socket:xwrite(line, "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_status_line(httpversion, status_code, reason_phrase, timeout)
	assert(httpversion == 1.0 or httpversion == 1.1)
	assert(status_code:match("^[1-9]%d%d$"), "invalid status code")
	assert(type(reason_phrase) == "string" and reason_phrase:match("^[^\r\n]*$"), "invalid reason phrase")
	local line = string.format("HTTP/%1.1f %s %s\r\n", httpversion, status_code, reason_phrase)
	local ok, err, errno = self.socket:xwrite(line, "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_header(k, v, timeout)
	assert(type(k) == "string" and k:match("^[^:\r\n]+$"), "field name invalid")
	assert(type(v) == "string" and v:sub(-1, -1) ~= "\n" and not v:match("\n[^ ]"), "field value invalid")
	local ok, err, errno = self.socket:xwrite(k..": "..v.."\r\n", "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_headers_done(timeout)
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite("\r\n", "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_chunk(chunk, chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	local data = string.format("%x\r\n", #chunk) .. chunk .. "\r\n"
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite(data, "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_last_chunk(chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	-- no flush; writing trailers (via write_headers_done) will do that
	local ok, err, errno = self.socket:xwrite("0\r\n", "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_plain(body, timeout)
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite(body, "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

return {
	new = new_connection;
	methods = connection_methods;
	mt = connection_mt;
}
