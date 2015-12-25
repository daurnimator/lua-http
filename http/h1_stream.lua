local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local new_fifo = require "fifo"
local new_headers = require "http.headers".new
local reason_phrases = require "http.h1_reason_phrases"
local stream_common = require "http.stream_common"
local has_zlib, zlib = pcall(require, "http.zlib")

local function has(list, val)
	for i=1, list.n do
		if list[i]:lower() == val then
			return true
		end
	end
	return false
end

local function has_any(list, val, ...)
	if has(list, val) then
		return true
	elseif (...) then
		return has(list, ...)
	else
		return false
	end
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
	return string.format("http.h1_stream{connection=%s;state=%q}",
		tostring(self.connection), self.state)
end

local function new_stream(connection)
	local self = setmetatable({
		connection = connection;
		type = connection.type;

		state = "idle";
		stats_sent = 0;

		pipeline_cond = cc.new(); -- signalled when stream reaches front of pipeline

		req_method = nil; -- string
		peer_version = nil; -- 1.0 or 1.1
		headers_fifo = new_fifo();
		headers_cond = cc.new();
		body_write_type = nil; -- "closed", "chunked", "length" or "missing"
		body_write_left = nil; -- integer: only set when body_write_type == "length"
		body_write_deflate = nil; -- nil or stateful deflate closure
		body_read_type = nil;
		body_read_inflate = nil;
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
			if self.close_when_done then
				self.connection:shutdown("r")
			end
			-- remove our read lock
			assert(self.connection.req_locked == self)
			self.connection.req_locked = nil
			self.connection.req_cond:signal(1)
		end
		-- If we have just finished writing the response
		if (old == "idle" or old == "open" or old == "half closed (remote)")
			and (new == "half closed (local)" or new == "closed") then
			if self.close_when_done then
				self.connection:shutdown()
			end
			-- remove ourselves from the write pipeline
			assert(self.connection.pipeline:pop() == self)
			local next_stream = self.connection.pipeline:peek()
			if next_stream then
				next_stream.pipeline_cond:signal()
			end
		end
	else -- client
		-- If we have just finished writing the request
		if (old == "open" or old == "half closed (remote)")
			and (new == "half closed (local)" or new == "closed") then
			-- NOTE: You cannot shutdown("w") the socket here.
			-- many servers will close the connection if the client closes their write stream

			-- remove our write lock
			assert(self.connection.req_locked == self)
			self.connection.req_locked = nil
			self.connection.req_cond:signal(1)
		end
		-- If we have just finished reading the response;
		if (old == "idle" or old == "open" or old == "half closed (local)")
			and (new == "half closed (remote)" or new == "closed") then
			if self.close_when_done then
				self.connection:shutdown()
			end
			-- remove ourselves from the read pipeline
			assert(self.connection.pipeline:pop() == self)
			local next_stream = self.connection.pipeline:peek()
			if next_stream then
				next_stream.pipeline_cond:signal()
			end
		end
	end
end

local server_error_headers = new_headers()
server_error_headers:append(":status", "503")
function stream_methods:shutdown()
	if self.type == "client" and self.state == "half closed (local)" then
		-- If we're a client and have fully sent our request body,
		-- we'd like to finishing reading any remaining response so that we get out of the way
		repeat
			-- don't bother continuing if we're reading until connection is closed
			if self.body_read_type == "close" then
				self.connection:shutdown("rw")
				break
			end
		until self:get_next_chunk() == nil -- ignore errors
	end
	if self.state == "open" or self.state == "half closed (remote)" then
		if not self.body_write_type and self.type == "server" then
			-- Can send server error response
			local ok = self:write_headers(server_error_headers, true)
			if not ok then
				self.connection:shutdown("w")
			end
		else
			-- This is a bad situation: we are trying to shutdown a connection that has the body partially sent
			-- Especially in the case of Connection: close, where closing indicates EOF,
			-- this will result in a client only getting a partial response.
			-- Could also end up here if a client sending headers fails.
			self.connection:shutdown("w")
		end
	end
	self:set_state("closed")
end

-- read_headers may be called more than once for a stream
-- e.g. for 100 Continue
-- this function *should never throw* under normal operation
function stream_methods:read_headers(timeout)
	local deadline = timeout and (monotime()+timeout)
	local headers = new_headers()
	local status_code
	if self.body_read_type == "chunked" then
		error("NYI: trailers")
	elseif self.type == "server" then
		if self.state ~= "idle" and self.state ~= "open" then
			return nil, ce.EPIPE
		end
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
		if self.state ~= "open" and self.state ~= "half closed (local)" then
			return nil, ce.EPIPE
		end
		-- Make sure we're at front of connection pipeline
		if self.connection.pipeline:peek() ~= self then
			if not self.pipeline_cond:wait(deadline and (deadline-monotime)) then
				return nil, ce.ETIMEDOUT
			end
			assert(self.connection.pipeline:peek() == self)
		end
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

	-- if client is sends `Connection: close`, server knows it can close at end of response
	if has(headers:get_split_as_sequence("connection"), "close") then
		self.close_when_done = true
	end

	-- Now guess if there's a body...
	-- RFC 7230 Section 3.3.3
	local no_body
	if self.type == "client" and (
		self.req_method == "HEAD"
		or status_code == "204"
		or status_code == "304"
	) then
		no_body = true
	elseif self.type == "client" and (
		status_code:sub(1,1) == "1"
	) then
		-- note: different to spec:
		-- we don't want to go into body reading mode;
		-- we want to stay in header modes
		no_body = false
	elseif headers:has("transfer-encoding") then
		no_body = false
		local transfer_encoding = headers:get_split_as_sequence("transfer-encoding")
		local n = transfer_encoding.n
		if transfer_encoding[n] == "chunked" then
			self.body_read_type = "chunked"
			n = n - 1
		else
			self.body_read_type = "close"
		end
		if transfer_encoding[n] == "gzip" or transfer_encoding[n] == "deflate" then
			self.body_read_inflate = zlib.inflate()
			n = n - 1
		end
		if n > 0 then
			return nil, "unknown transfer-encoding"
		end
	elseif headers:has("content-length") then
		local cl = tonumber(headers:get("content-length"), 10)
		if cl == nil then
			return nil, "invalid content-length"
		end
		if cl == 0 then
			no_body = true
		else
			no_body = false
			self.body_read_type = "length"
			self.body_read_left = cl
		end
	elseif self.type == "server" then
		-- A request defaults to no body
		no_body = true
	else -- client
		no_body = false
		self.body_read_type = "close"
	end
	if no_body then
		if self.state == "open" then
			self:set_state("half closed (remote)")
		else -- self.state == "half closed (local)"
			self:set_state("closed")
		end
	else
		if self.type == "server" then
			local te = headers:get_split_as_sequence("te")
			-- TODO: need to take care of quality suffixes ("deflate; q=0.5")
			if has_zlib and has_any(te, "gzip", "deflate") then
				self.body_write_deflate = zlib.deflate()
			end
		end
	end

	return headers
end

function stream_methods:get_headers(timeout)
	if self.headers_fifo:length() == 0 then
		-- TODO: locking?
		return self:read_headers(timeout)
	end
	return self.headers_fifo:pop()
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
	local status_code, method
	if self.type == "server" then
		-- Make sure we're at the front of the pipeline
		if self.connection.pipeline:peek() ~= self then
			if not self.pipeline_cond:wait(deadline and (deadline-monotime)) then
				return nil, ce.ETIMEDOUT
			end
			assert(self.connection.pipeline:peek() == self)
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
			method = assert(headers:get(":method"), "missing method")
			self.req_method = method
			local path
			if method == "CONNECT" then
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
			local ok, err = self.connection:write_request_line(method, path, self.connection.version, deadline and (deadline-monotime()))
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
	elseif self.type == "server" and status_code and status_code:sub(1, 1) == "1" then
		assert(not end_stream, "cannot end stream directly after 1xx status code")
		-- A server MUST NOT send a Content-Length header field in any response with a status code of 1xx (Informational) or 204 (No Content)
		if cl then
			error("Content-Length not allowed in response with 1xx status code")
		end
	elseif not self.body_write_type then -- only figure out how to send the body if we haven't figured it out yet... TODO: use better check
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
				if status_code == "204" then
					error("Content-Length not allowed in response with 204 status code")
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
				elseif self.type ~= "client" or (method ~= "GET" and method ~= "HEAD") then
					cl = "0"
				end
				self.body_write_type = "length"
				self.body_write_left = 0
			end
		else
			-- The order of these checks matter:
				-- chunked must be checked first, as it totally changes the body format
				-- content-length is next
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
		if has_zlib then
			if self.type == "client" then
				-- If we support zlib; add a "te" header indicating we support the gzip transfer-encoding
				if not has(connection_header, "te") then
					connection_header.n = connection_header.n + 1
					connection_header[connection_header.n] = "te"
				end
				local ok, err = self.connection:write_header("te", "gzip", deadline and (deadline-monotime()))
				if not ok then
					if err == ce.EPIPE or err == ce.ETIMEDOUT then
						return nil, err
					end
					error(err)
				end
			else -- server
				-- Whether to use transfer-encoding: gzip
				if self.body_write_deflate -- only use if client sent the TE header allowing it
					and not cl -- not allowed to use both content-length *and* transfer-encoding
					and not end_stream -- no point encoding body if there isn't one
					and not has_any(headers:get_split_as_sequence("content-encoding"), "gzip", "deflate")
					-- don't bother if content-encoding is already gzip/deflate
					-- TODO: need to take care of quality suffixes ("deflate; q=0.5")
				then
					-- Possibly need to insert before "chunked"
					local i = transfer_encoding_header.n
					if transfer_encoding_header[i] == "chunked" then
						table.insert(transfer_encoding_header, i, "gzip")
						transfer_encoding_header.n = i + 1
					elseif transfer_encoding_header[i] ~= "gzip" and transfer_encoding_header[i] ~= "deflate" then
						i = i + 1
						transfer_encoding_header[i] = "gzip"
						transfer_encoding_header.n = i
					end
				else
					-- discard the encoding context (if there was one)
					self.body_write_deflate = nil
				end
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

function stream_methods:get_next_chunk(timeout)
	if self.state == "closed" or self.state == "half closed (remote)" then
		return nil, ce.EPIPE
	end
	local chunk, end_stream
	local err, errno
	if self.body_read_type == "chunked" then
		local deadline = timeout and (monotime()+timeout)
		chunk, err, errno = self.connection:read_body_chunk(timeout)
		if chunk == false then
			-- read trailers
			local trailers = new_headers()
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
				trailers:append(k, v)
			end
			self.headers_fifo:push(trailers)
			self.headers_cond:signal(1)

			chunk, err, errno = nil, ce.EPIPE, nil
			end_stream = true
		else
			end_stream = false
		end
	elseif self.body_read_type == "length" then
		local length_n = self.body_read_left
		if length_n > 0 then
			-- Read *upto* length_n bytes
			-- This function only has to read chunks; not the whole body
			chunk, err, errno = self.connection:read_body_by_length(-length_n, timeout)
			if chunk ~= nil then
				self.body_read_left = length_n - #chunk
				end_stream = (self.body_read_left == 0)
			end
		elseif length_n == 0 then
			chunk = ""
			end_stream = true
		else
			error("invalid length: "..tostring(length_n))
		end
	elseif self.body_read_type == "close" then
		-- Use a big negative number instead of *a. see https://github.com/wahern/cqueues/issues/89
		chunk, err, errno = self.connection:read_body_by_length(-0x80000000, timeout)
		end_stream = (err == ce.EPIPE)
	elseif self.body_read_type == nil then
		-- Might get here if haven't read headers yet, or if only headers so far have been 1xx codes
		local deadline = timeout and (monotime()+timeout)
		local headers
		headers, err, errno = self:read_headers(timeout)
		if not headers then
			return nil, err, errno
		end
		self.headers_fifo:push(headers)
		self.headers_cond:signal(1)
		return self:get_next_chunk(deadline and deadline-monotime())
	else
		error("unknown body read type")
	end
	if chunk and self.body_read_inflate then
		chunk = self.body_read_inflate(chunk, end_stream)
	end
	if end_stream then
		if self.state == "half closed (local)" then
			self:set_state("closed")
		else
			self:set_state("half closed (remote)")
		end
	end
	return chunk, err, errno
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
	if self.body_write_deflate then
		chunk = self.body_write_deflate(chunk, end_stream)
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
			-- TODO: trailers?
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
