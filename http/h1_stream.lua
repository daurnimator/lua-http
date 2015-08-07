local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local new_headers = require "http.headers".new
local reason_phrases = require "http.h1_reason_phrases"
local stream_common = require "http.stream_common"
local http_util = require "http.util"

local function has(list, val)
	for i=1, list.n do
		if list[i] == val then
			return true
		end
	end
	return false
end

local stream_methods = {}
for k,v in pairs(stream_common.methods) do
	stream_methods[k] = v
end
local stream_mt = {
	__name = "http.h1_stream";
	__index = stream_methods;
}

function stream_mt:__tostring()
	return string.format("http.h1_stream{state=%q}", self.state)
end

local function new_stream(connection)
	local self = setmetatable({
		connection = connection;
		type = connection.type;

		state = "idle";
		state_cond = cc.new();
		stats_sent = 0;

		req_method = nil;
		peer_version = nil;
		headers = new_headers();
		headers_cond = cc.new();
		body_write_type = nil;
		body_write_left = nil;
		close_when_done = nil;
	}, stream_mt)
	return self
end

local valid_states = {
	["idle"] = true; -- initial
	["open"] = true; -- have sent or received headers; haven't sent body yet
	["half closed (local)"] = true; -- have sent whole body
	["half closed (remote)"] = true; -- have received whole body
	["closed"] = true; -- complete
}
function stream_methods:set_state(new)
	assert(valid_states[new])
	local old = self.state
	self.state = new
	-- If we have just finished reading; remove our read lock
	if (old == "idle" or old == "open" or old == "half closed (local)")
		and (new == "half closed (remote)" or new == "closed") then
		self.connection.reading_locked = false
		self.connection.reading_cond:signal(1)
	end
	-- If we have just finished writing; remove ourselves from the write pipeline
	if (old == "idle" or old == "open" or old == "half closed (remote)")
		and (new == "half closed (local)" or new == "closed") then
		assert(self.connection.pipeline:pop() == self)
	end
	self.state_cond:signal()
end

function stream_methods:shutdown()
	if self.state == "open" or (self.type == "client" and self.state == "half closed (local)") then
		-- need to clean out pipeline by reading it.
		for _ in self:each_chunk() do
			-- ignore them
		end
	end
	if self.state == "half closed (remote)" and self.type == "server" and self.body_write_type then
		-- TODO: finish sending body
		local fake_chunk
		if self.body_write_type == "length" then
			fake_chunk = ("\0"):rep(self.body_write_left)
		else
			fake_chunk = ""
		end

		self:write_chunk(fake_chunk, true)
	end
	self:set_state("closed")
end

-- this function *should never throw* under normal operation
function stream_methods:get_headers(timeout)
	local deadline = timeout and (monotime()+timeout)
	if self.type == "server" and self.state == "idle" then
		local method, path, httpversion = -- luacheck: ignore 211
			self.connection:read_request_line(deadline and (deadline-monotime()))
		if method == nil then return nil, path, httpversion end
		self.req_method = method
		self.peer_version = httpversion
		self.headers:append(":method", method)
		if method == "CONNECT" then
			self.headers:append(":authority", path)
		else
			self.headers:append(":path", path)
		end
		self.headers:append(":scheme", self:checktls() and "https" or "http")
		self:set_state("open")
	elseif self.type == "client"
		and (self.state == "open" or self.state == "half closed (local)")
		and not self.headers:has(":status") then
		local httpversion, status_code, reason_phrase = -- luacheck: ignore 211
			self.connection:read_status_line(deadline and (deadline-monotime()))
		if httpversion == nil then return nil, status_code, reason_phrase end
		self.peer_version = httpversion
		self.headers:append(":status", status_code)
	elseif self.state == "idle" then -- client
		error("programming error: no headers sent, what do you expect to receive?")
	else -- no more headers to get
		return self.headers
	end
	-- Use while loop for lua 5.1 compatibility
	while true do
		local k, v = self.connection:next_header(deadline and (deadline-monotime()))
		if k == nil then break end
		k = k:lower() -- normalise to lower case
		if k == "host" then
			k = ":authority"
		end
		self.headers:append(k, v)
	end
	self.headers_cond:signal();
	-- Now guess if there's a body...
	local no_body
	if self.type == "client" then
		-- if it was a HEAD request there will be no body
		no_body = (self.req_method == "HEAD")
	else -- server
		no_body = (self.req_method == "GET" or self.req_method == "HEAD")
			and not (self.headers:has("content-length")
			or self.headers:has("content-type")
			or self.headers:has("transfer-encoding"))
	end
	if no_body then
		if self.state == "open" then
			self:set_state("half closed (remote)")
		else -- self.state == "half closed (local)"
			self:set_state("closed")
		end
	end
	return self.headers
end

local ignore_fields = {
	[":authority"] = true;
	[":method"] = true;
	[":path"] = true;
	[":scheme"] = true;
	[":status"] = true;
}
function stream_methods:write_headers(headers, end_stream, timeout)
	local deadline = timeout and (monotime()+timeout)
	assert(headers, "missing argument: headers")
	if self.type == "server" then
		if self.state == "closed" or self.state == "half closed (local)" then
			error(ce.EPIPE)
		end
		assert(self.state == "open" or self.state == "half closed (remote)")
		-- Make sure we're at the front of the pipeline
		if self.connection.pipeline:peek() ~= self then
			error("NYI")
		end
		local status_code = assert(headers:get(":status"), "missing status")
		local reason_phrase = reason_phrases[status_code]
		local ok, err = self.connection:write_status_line(self.connection.version, status_code, reason_phrase, deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	else -- client
		assert(self.state == "idle" or self.state == "open")
		self.req_method = headers:get(":method")
		local path
		if self.req_method == "CONNECT" then
			path = assert(headers:get(":authority"), "missing authority")
			assert(not headers:has(":path"), "CONNECT requests should not have a path")
		else
			path = assert(headers:get(":path"), "missing path")
		end
		local ok, err = self.connection:write_request_line(self.req_method, path, self.connection.version, deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	end

	if self.req_method == "CONNECT" then
		self.body_write_type = "close"
		self.close_when_done = true
	else
		local cl = headers:get("content-length")
		local connection = headers:get_comma_separated("connection")
		connection = connection and http_util.split_header(connection)
		if self.peer_version == 1.0 then
			self.close_when_done = not connection or not has(connection, "keep-alive")
		else
			self.close_when_done = connection and has(connection, "close")
		end
		if end_stream then
			-- Make sure 'end_stream' is respected
			if self.connection.type ~= "server"
				and self.req_method ~= "HEAD" and not self.close_when_done then
				-- By adding `content-length: 0` we can be sure that a server won't wait for a body
				-- This is somewhat suggested in RFC 7231 section 8.1.2
				local ok, err = self.connection:write_header("content-length", "0", deadline and (deadline-monotime()))
				if not ok then
					if err == ce.EPIPE or err == ce.ETIMEDOUT then
						return nil, err
					end
					error(err)
				end
			end
		else
			local te = http_util.split_header(headers:get_comma_separated("transfer-encoding"))
			if te[#te] == "chunked" then
				self.body_write_type = "chunked"
			elseif cl then
				self.body_write_type = "length"
				self.body_write_left = assert(tonumber(cl), "invalid content-length")
			elseif self.close_when_done then
				self.body_write_type = "close"
			elseif self.connection.type == "server" then
				-- default for servers if they don't send a particular header
				self.body_write_type = "close"
				self.close_when_done = true
			else
				error("unknown body type")
			end
		end
	end


	for name, value in headers:each() do
		if not ignore_fields[name] then
			local ok, err = self.connection:write_header(name, value, deadline and (deadline-monotime()))
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
		elseif name == ":authority" then
			-- for CONNECT requests, :authority is the path
			if self.req_method ~= "CONNECT" then
				-- otherwise it's the Host header
				local ok, err = self.connection:write_header("host", value, deadline and (deadline-monotime()))
				if not ok then
					if err == ce.EPIPE or err == ce.ETIMEDOUT then
						return nil, err
					end
					error(err)
				end
			end
		end
	end
	local ok, err = self.connection:write_headers_done(deadline and (deadline-monotime()))
	if not ok then
		if err == ce.EPIPE or err == ce.ETIMEDOUT then
			return nil, err
		end
		error(err)
	end

	if end_stream then
		self:set_state("half closed (local)")
		if self.close_when_done then
			self.connection.socket:shutdown("w")
		end
	elseif self.state == "idle" then
		self:set_state("open")
	end
end

local function read_body_iter(headers)
	local get_more

	local te = http_util.split_header(headers:get_comma_separated("transfer-encoding"))
	local cl = headers:get("content-length")
	if te[#te] == "chunked" then
		local got_trailers = false
		function get_more(self, timeout)
			if got_trailers then
				return nil, ce.EPIPE
			end
			local chunk, err, errno = self.connection:read_body_chunk(timeout)
			if chunk == nil then
				if err == ce.EPIPE then
					-- read trailers
					-- TODO: check against trailer header as whitelist?
					while true do
						local k, v, errno2 = self.connection:next_header()
						if k == nil then
							return nil, v, errno2
						end
						self.headers:append(k, v)
					end
					got_trailers = true
					self.headers_cond:signal()
				end
				return nil, err, errno
			end
			return chunk
		end
		te[#te] = nil
	elseif cl then
		assert(#cl < 13, "content-length too long")
		assert(cl:match("^%d+$"), "invalid content-length")
		local length_n = tonumber(cl)
		function get_more(self, timeout)
			if length_n <= 0 then
				return nil, ce.EPIPE
			end
			local chunk, err, errno = self.connection:read_body_by_length(-length_n, timeout)
			if chunk == nil then
				return nil, err, errno
			end
			length_n = length_n - #chunk
			return chunk
		end
	else -- read until close
		local closed = false
		function get_more(self, timeout)
			if closed then
				return nil, ce.EPIPE
			end
			local chunk, err, errno = self.connection:read_body_by_length(-0x80000000, timeout)
			if chunk == nil then
				if err == ce.EPIPE then
					closed = true
				end
				return nil, err, errno
			end
			return chunk
		end
	end

	assert(te[1] == nil, "unknown transfer-encoding")

	return get_more
end

function stream_methods:get_next_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	local headers = self:get_headers(timeout)
	local get_more = read_body_iter(headers)
	self.get_next_chunk = function(self, timeout) -- luacheck: ignore 212 432
		local chunk, err, errno = get_more(self, timeout)
		if chunk == nil then
			if err == ce.EPIPE then
				if self.state == "half closed (local)" then
					self:set_state("closed")
				else
					self:set_state("half closed (remote)")
				end
			end
			return nil, err, errno
		end
		return chunk
	end
	return get_more(self, deadline and (deadline-monotime()))
end

function stream_methods:write_chunk(chunk, end_stream, timeout)
	if self.state ~= "open" and self.state ~= "half closed (remote)" then
		error("cannot write chunk when stream is " .. self.state)
	end
	if self.body_write_type == "chunked" then
		local deadline = timeout and (monotime()+timeout)
		if #chunk > 0 then
			local ok, err = self.connection:write_body_chunk(chunk, nil, timeout)
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
			timeout = deadline and (deadline-monotime())
		end
		if end_stream then
			local ok, err = self.connection:write_body_last_chunk(nil, timeout)
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
			timeout = deadline and (deadline-monotime())
			ok, err = self.connection:write_headers_done(timeout)
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
		end
	elseif self.body_write_type == "length" then
		if #chunk > 0 then
			local ok, err = self.connection:write_body_plain(chunk, timeout)
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
			self.body_write_left = self.body_write_left - #chunk
		end
		if end_stream then
			assert(self.body_write_left == 0, "invalid content-length")
		end
	elseif self.body_write_type == "close" then
		if #chunk > 0 then
			local ok, err = self.connection:write_body_plain(chunk, timeout)
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
		end
	else
		error("cannot write chunk")
	end
	self.stats_sent = self.stats_sent + #chunk
	if end_stream then
		if self.close_when_done then
			self.connection.socket:shutdown("w")
		end
		if self.state == "half closed (remote)" then
			self:set_state("closed")
		else
			self:set_state("half closed (local)")
		end
	end
end

return {
	new = new_stream;
	methods = stream_methods;
	mt = stream_mt;
}
