local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ce = require "cqueues.errno"
local new_headers = require "http.headers".new
local reason_phrases = require "http.h1_reason_phrases"
local stream_common = require "http.stream_common"

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
		stats_sent = 0;

		req_method = nil; -- string
		peer_version = nil; -- 1.0 or 1.1
		body_write_type = nil; -- "closed", "chunked", "length" or "missing"
		body_write_left = nil; -- integer: only set when body_write_type == "length"
		body_read_transfer_encoding = nil; -- sequence: transfer-encoding header from peer
		body_read_left = nil; -- string: content-length header from peer
		close_when_done = nil; -- boolean
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
	if self.type == "server" then
		-- If we have just finished reading the request
		if (old == "idle" or old == "open" or old == "half closed (local)")
			and (new == "half closed (remote)" or new == "closed") then
			-- remove our read lock
			assert(self.connection.req_locked == self)
			self.connection.req_locked = nil
			self.connection.req_cond:signal(1)
		end
		-- If we have just finished writing the response
		if (old == "idle" or old == "open" or old == "half closed (remote)")
			and (new == "half closed (local)" or new == "closed") then
			-- remove ourselves from the write pipeline
			assert(self.connection.pipeline:pop() == self)
		end
	else -- client
		-- If we have just finished writing the request
		if (old == "open" or old == "half closed (remote)")
			and (new == "half closed (local)" or new == "closed") then
			-- remove our write lock
			assert(self.connection.req_locked == self)
			self.connection.req_locked = nil
			self.connection.req_cond:signal(1)
		end
		-- If we have just finished reading the response;
		if (old == "idle" or old == "open" or old == "half closed (local)")
			and (new == "half closed (remote)" or new == "closed") then
			-- remove ourselves from the read pipeline
			assert(self.connection.pipeline:pop() == self)
		end
	end
end

local server_error_headers = new_headers()
server_error_headers:append(":status", "503")
function stream_methods:shutdown()
	if self.type == "client" and self.state == "half closed (local)" then
		-- If we're a client and have fully sent our request body
		-- we'd like to finishing reading any remaining response so that we get out of the way
		-- TODO: don't bother if we're reading until connection is closed
		-- ignore errors
		while self:get_next_chunk() do end
	end
	if self.state == "open" or self.state == "half closed (remote)" then
		if not self.body_write_type and self.type == "server" then
			-- Can send server error response
			local ok, err = self:write_headers(server_error_headers, true)
			if not ok then
				self.connection.socket:shutdown("w")
			end
		else
			-- This is a bad situation: we are trying to shutdown a connection that has the body partially sent
			-- Especially in the case of Connection: close, where closing indicates EOF,
			-- this will result in a client only getting a partial response.
			-- Could also end up here if a client sending headers fails.
			self.connection.socket:shutdown("w")
		end
	end
	self:set_state("closed")
end

-- get_headers may be called more than once for a stream
-- e.g. for 100 Continue
-- this function *should never throw* under normal operation
function stream_methods:get_headers(timeout)
	local deadline = timeout and (monotime()+timeout)
	local headers = new_headers()
	local status_code
	if self.type == "server" then
		assert(self.state == "idle")
		local method, path, httpversion =
			self.connection:read_request_line(deadline and (deadline-monotime()))
		if method == nil then
			return nil, path, httpversion
		end
		self.req_method = method
		self.peer_version = httpversion
		headers:append(":method", method)
		if method == "CONNECT" then
			headers:append(":authority", path)
		else
			headers:append(":path", path)
		end
		headers:append(":scheme", self:checktls() and "https" or "http")
		self:set_state("open")
	else -- client
		assert(self.state == "open" or self.state == "half closed (local)")
		-- Make sure we're at front of connection pipeline
		assert(self.connection.pipeline:peek() == self)
		local httpversion, reason_phrase
		httpversion, status_code, reason_phrase =
			self.connection:read_status_line(deadline and (deadline-monotime()))
		if httpversion == nil then
			return nil, status_code, reason_phrase
		end
		self.peer_version = httpversion
		headers:append(":status", status_code)
		-- reason phase intentionally does not exist in HTTP2; discard for consistency
	end
	-- Use while loop for lua 5.1 compatibility
	while true do
		local k, v = self.connection:read_header(deadline and (deadline-monotime()))
		if k == nil then
			-- if it was an error, it will be repeated
			local ok, err, errno2 = self.connection:read_headers_done(deadline and (deadline-monotime()))
			if ok == nil then
				return nil, err, errno2
			end
			break -- Success: End of headers.
		end
		k = k:lower() -- normalise to lower case
		if k == "host" then
			k = ":authority"
		end
		headers:append(k, v)
	end

	self.body_read_transfer_encoding = headers:get_split_as_sequence("transfer-encoding")
	self.body_read_left = headers:get("content-length")

	-- Now guess if there's a body...
	local no_body
	if self.type == "client" then
		-- RFC 7230 Section 3.3
		no_body = (self.req_method == "HEAD"
			or status_code == "204"
			or status_code:sub(1,1) == "1"
			or status_code == "304")
	else -- server
		-- GET and HEAD requests usually don't have bodies
		-- but if client sends a header that implies a body, assume it does
		-- don't include `connection: close` here
			-- some clients (e.g. siege) send it without closing.
		no_body = (self.req_method == "GET" or self.req_method == "HEAD")
			and not (headers:has("content-length")
			or headers:has("content-type")
			or headers:has("transfer-encoding"))

		-- if client is sends `Connection: close`, server knows it can close at end of response
		if has(headers:get_split_as_sequence("connection"), "close") then
			self.close_when_done = true
		end
	end
	if no_body then
		if self.state == "open" then
			self:set_state("half closed (remote)")
		else -- self.state == "half closed (local)"
			self:set_state("closed")
		end
	end
	return headers
end

local ignore_fields = {
	[":authority"] = true;
	[":method"] = true;
	[":path"] = true;
	[":scheme"] = true;
	[":status"] = true;
	-- fields written manually in :write_headers
	["connection"] = true;
	["content-length"] = true;
	["transfer-encoding"] = true;
}
-- Writes the given headers to the stream; optionally ends the stream at end of headers
--
-- We're free to insert any of the "Hop-by-hop" headers (as listed in RFC 2616 Section 13.5.1)
-- Do this by directly writing the headers, rather than adding them to the passed headers object,
-- as we don't want to modify the caller owned object.
-- Note from RFC 7230 Appendix 2:
--     "hop-by-hop" header fields are required to appear in the Connection header field;
--     just because they're defined as hop-by-hop doesn't exempt them.
function stream_methods:write_headers(headers, end_stream, timeout)
	local deadline = timeout and (monotime()+timeout)
	assert(headers, "missing argument: headers")
	assert(type(end_stream) == "boolean", "'end_stream' MUST be a boolean")
	if self.state == "closed" or self.state == "half closed (local)" then
		return nil, ce.EPIPE
	end
	local status_code
	if self.type == "server" then
		assert(self.state == "open" or self.state == "half closed (remote)")
		-- Make sure we're at the front of the pipeline
		if self.connection.pipeline:peek() ~= self then
			error("NYI")
		end
		status_code = headers:get(":status")
		if status_code then
			-- Should send status line
			local reason_phrase = reason_phrases[status_code]
			local ok, err = self.connection:write_status_line(self.connection.version, status_code, reason_phrase, deadline and (deadline-monotime()))
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
		end
	else -- client
		if self.state == "idle" then
			self.req_method = assert(headers:get(":method"), "missing method")
			local path
			if self.req_method == "CONNECT" then
				path = assert(headers:get(":authority"), "missing authority")
				assert(not headers:has(":path"), "CONNECT requests should not have a path")
			else
				path = assert(headers:get(":path"), "missing path")
			end
			if self.req_locked then
				-- Wait until previous responses have been fully written
				if not self.connection.req_cond:wait(deadline and (deadline-monotime())) then
					return nil, ce.ETIMEDOUT
				end
				assert(self.req_locked == nil)
			end
			self.connection.pipeline:push(self)
			self.connection.req_locked = self
			-- write request line
			local ok, err = self.connection:write_request_line(self.req_method, path, self.connection.version, deadline and (deadline-monotime()))
			if not ok then
				if err == ce.EPIPE or err == ce.ETIMEDOUT then
					return nil, err
				end
				error(err)
			end
			self:set_state("open")
		else
			assert(self.state == "open")
		end
	end

	local connection_header = headers:get_split_as_sequence("connection")
	local transfer_encoding_header = headers:get_split_as_sequence("transfer-encoding")
	local cl = headers:get("content-length") -- ignore subsequent content-length values
	if self.req_method == "CONNECT" and (self.type == "client" or status_code == "200") then
		-- successful CONNECT requests always continue until the connection is closed
		self.body_write_type = "close"
		self.close_when_done = true
		if self.type == "server" and (cl or transfer_encoding_header.n > 0) then
			-- RFC 7231 Section 4.3.6:
			-- A server MUST NOT send any Transfer-Encoding or Content-Length header
			-- fields in a 2xx (Successful) response to CONNECT.
			error("Content-Length and Transfer-Encoding not allowed with successful CONNECT response")
		end
	else
		if self.close_when_done == nil then
			if self.connection.version == 1.0 or (self.type == "server" and self.peer_version == 1.0) then
				self.close_when_done = not has(connection_header, "keep-alive")
			else
				self.close_when_done = has(connection_header, "close")
			end
		end
		if cl then
			-- RFC 7230 Section 3.3.2:
			-- A sender MUST NOT send a Content-Length header field in any message that contains a Transfer-Encoding header field.
			if transfer_encoding_header.n > 0 then
				error("Content-Length not allowed in message with a transfer-encoding")
			elseif self.type == "server" then
				-- A server MUST NOT send a Content-Length header field in any response with a status code of 1xx (Informational) or 204 (No Content)
				if status_code == "204"then
					error("Content-Length not allowed in response with 204 status code")
				elseif status_code:sub(1,1) == "1" then
					error("Content-Length not allowed in response with 1xx status code")
				end
			end
		end
		if end_stream then
			-- Make sure 'end_stream' is respected
			if self.type == "server" and (self.req_method == "HEAD" or status_code == "304") then
				self.body_write_type = "missing"
			elseif transfer_encoding_header.n > 0 then
				if transfer_encoding_header[transfer_encoding_header.n] == "chunked" then
					-- Set body type to chunked so that we know how to end the stream
					self.body_write_type = "chunked"
				else
					error("unknown transfer-encoding")
				end
			else
				-- By adding `content-length: 0` we can be sure that our peer won't wait for a body
				-- This is somewhat suggested in RFC 7231 section 8.1.2
				if cl then -- might already have content-length: 0
					assert(cl:match("^ *0+ *$"), "cannot end stream after headers if you have a non-zero content-length")
				else
					cl = "0"
				end
				self.body_write_type = "length"
				self.body_write_left = 0
			end
		else
			-- The order of these checks matter:
				-- chunked must be checked first, as it totally changes the body format
				-- content-length is next
					-- note that Content-Length may be provided in addition to "chunked"
					-- e.g. to advise peer to preallocate a certain file size
				-- closing the connection is ordered after length
					-- this potentially means an early EOF can be caught if a connection
					-- closure occurs before body size reaches the specified length
				-- for HTTP/1.1, we can fall-back to a chunked encoding
					-- chunked is mandatory to implement in HTTP/1.1
					-- this requires amending the transfer-encoding header
				-- for a HTTP/1.0 server, we fall-back to closing the connection at the end of the stream
				-- else is a HTTP/1.0 client with `connection: keep-alive` but no other header indicating the body form.
					-- this cannot be reasonably handled, so throw an error.
			if transfer_encoding_header[transfer_encoding_header.n] == "chunked" then
				self.body_write_type = "chunked"
			elseif cl then
				self.body_write_type = "length"
				self.body_write_left = assert(tonumber(cl, 10), "invalid content-length")
			elseif self.close_when_done then -- ordered after length delimited
				self.body_write_type = "close"
			elseif self.connection.version == 1.1 and (self.type == "client" or self.peer_version == 1.1) then
				self.body_write_type = "chunked"
				-- transfer-encodings are ordered. we need to make sure we place "chunked" last
				transfer_encoding_header.n = transfer_encoding_header.n + 1
				transfer_encoding_header[transfer_encoding_header.n] = "chunked"
			elseif self.type == "server" then
				-- default for servers if they don't send a particular header
				self.body_write_type = "close"
				self.close_when_done = true
			else
				error("a client cannot send a body with connection: keep-alive without indicating body delimiter in headers")
			end
		end
		-- Add 'Connection: close' header if we're going to close after
		if self.close_when_done and not has(connection_header, "close") then
			connection_header.n = connection_header.n + 1
			connection_header[connection_header.n] = "close"
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

	-- Write transfer-encoding, content-length and connection headers separately
	if transfer_encoding_header.n > 0 then
		-- Add to connection header
		if not has(connection_header, "transfer-encoding") then
			connection_header.n = connection_header.n + 1
			connection_header[connection_header.n] = "transfer-encoding"
		end
		local value = table.concat(transfer_encoding_header, ",", 1, transfer_encoding_header.n)
		local ok, err = self.connection:write_header("transfer-encoding", value, deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	elseif cl then
		local ok, err = self.connection:write_header("content-length", cl, deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	end
	if connection_header.n > 0 then
		local value = table.concat(connection_header, ",", 1, connection_header.n)
		local ok, err = self.connection:write_header("connection", value, deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	end

	do
		local ok, err = self.connection:write_headers_done(deadline and (deadline-monotime()))
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	end

	if end_stream then
		local ok, err = self:write_chunk("", true)
		if not ok then
			if err == ce.EPIPE or err == ce.ETIMEDOUT then
				return nil, err
			end
			error(err)
		end
	end

	return true
end

local function read_body_iter(te, cl)
	local get_more
	local te_n = te.n
	if te[te_n] == "chunked" then
		local got_trailers = false
		function get_more(self, timeout)
			if got_trailers then
				return nil, ce.EPIPE
			end
			local deadline = timeout and (monotime()+timeout)
			local chunk, err, errno = self.connection:read_body_chunk(timeout)
			if chunk == nil then
				return nil, err, errno
			elseif chunk == false then
				-- read trailers
				-- TODO: check against trailer header as whitelist?
				while true do
					local k, v = self.connection:read_header(deadline and (deadline-monotime()))
					if k == nil then
						-- if it was an error, it will be repeated
						local ok, err2, errno2 = self.connection:read_headers_done(deadline and (deadline-monotime()))
						if ok == nil then
							return nil, err2, errno2
						end
						break -- Success: End of headers.
					end
					-- self.trailers:append(k, v)
				end
				got_trailers = true
				return nil, ce.EPIPE
			else
				return chunk
			end
		end
		te_n = te_n - 1
	elseif cl then
		local length_n = tonumber(cl, 10)
		if not length_n or length_n < 0 then
			return nil, "invalid content-length"
		end
		function get_more(self, timeout)
			if length_n == 0 then
				return nil, ce.EPIPE
			end
			assert(length_n > 0)
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

	if te_n > 0 then
		return nil, "unknown transfer-encoding"
	end

	return get_more
end

function stream_methods:get_next_chunk(timeout)
	if self.state == "closed" or self.state == "half closed (remote)" then
		return nil, ce.EPIPE
	end
	local get_more, err = read_body_iter(self.body_read_transfer_encoding, self.body_read_left)
	if not get_more then
		return nil, err
	end
	self.get_next_chunk = function(self, timeout) -- luacheck: ignore 432
		local chunk, err2, errno2 = get_more(self, timeout)
		if chunk == nil then
			if err2 == ce.EPIPE then
				if self.state == "half closed (local)" then
					self:set_state("closed")
				else
					self:set_state("half closed (remote)")
				end
			end
			return nil, err2, errno2
		end
		return chunk
	end
	return self:get_next_chunk(timeout)
end

function stream_methods:write_chunk(chunk, end_stream, timeout)
	if self.state ~= "open" and self.state ~= "half closed (remote)" then
		error("cannot write chunk when stream is " .. self.state)
	end
	if self.type == "client" then
		assert(self.connection.req_locked == self)
	else
		assert(self.connection.pipeline:peek() == self)
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
	elseif self.body_write_type ~= "missing" then
		error("unknown body writing method")
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
	return true
end

return {
	new = new_stream;
	methods = stream_methods;
	mt = stream_mt;
}
