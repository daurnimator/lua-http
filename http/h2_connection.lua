local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local rand = require "openssl.rand"
local new_fifo = require "fifo"
local band = require "http.bit".band
local h2_error = require "http.h2_error"
local h2_stream = require "http.h2_stream"
local hpack = require "http.hpack"
local h2_banned_ciphers = require "http.tls".banned_ciphers
local spack = string.pack or require "compat53.string".pack
local sunpack = string.unpack or require "compat53.string".unpack

local assert = assert
if _VERSION:match("%d+%.?%d*") < "5.3" then
	assert = require "compat53.module".assert
end

local function xor(a, b)
	return (a and b) or not (a or b)
end

local preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

local default_settings = {
	[0x1] = 4096; -- HEADER_TABLE_SIZE
	[0x2] = true; -- ENABLE_PUSH
	[0x3] = math.huge; -- MAX_CONCURRENT_STREAMS
	[0x4] = 65535; -- INITIAL_WINDOW_SIZE
	[0x5] = 16384; -- MAX_FRAME_SIZE
	[0x6] = math.huge;  -- MAX_HEADER_LIST_SIZE
}

local function merge_settings(new, old)
	return {
		[0x1] = new[0x1] or old[0x1];
		[0x2] = new[0x2] or old[0x2];
		[0x3] = new[0x3] or old[0x3];
		[0x4] = new[0x4] or old[0x4];
		[0x5] = new[0x5] or old[0x5];
		[0x6] = new[0x6] or old[0x6];
	}
end

local connection_methods = {}
local connection_mt = {
	__name = "http.h2_connection";
	__index = connection_methods;
}

function connection_mt:__tostring()
	return string.format("http.h2_connection{type=%q}",
		self.type)
end

local connection_main_loop

-- An 'onerror' that doesn't throw
local function onerror(socket, op, why, lvl) -- luacheck: ignore 212
	if why == ce.EPIPE or why == ce.ETIMEDOUT then
		return why
	end
	return string.format("%s: %s", op, ce.strerror(why)), why
end

-- Read bytes from the given socket looking for the http2 connection preface
-- optionally ungets the bytes in case of failure
local function socket_has_preface(socket, unget, timeout)
	local deadline = timeout and (monotime()+timeout)
	local bytes = ""
	local is_h2 = true
	while #bytes < #preface do
		-- read *up to* number of bytes left in preface
		local ok, err, errno = socket:xread(#bytes-#preface, deadline and (deadline-monotime()))
		if ok == nil then
			return nil, err or ce.EPIPE, errno
		end
		bytes = bytes .. ok
		if bytes ~= preface:sub(1, #bytes) then
			is_h2 = false
			break
		end
	end
	if unget then
		local ok, errno = socket:unget(bytes)
		if not ok then
			return nil, onerror(socket, "unget", errno, 2)
		end
	end
	return is_h2
end

local function new_connection(socket, conn_type, settings, timeout)
	local deadline = timeout and (monotime()+timeout)

	local cq do -- Allocate cqueue first up, as it can throw when out of files
		local ok, err = pcall(cqueues.new)
		if not ok then
			local errno = ce.EMFILE
			return nil, ce.strerror(errno), errno
		end
		cq = err
	end

	socket:setmode("b", "bf")
	socket:setvbuf("full", math.huge) -- 'infinite' buffering; no write locks needed
	socket:onerror(onerror)

	local ssl = socket:checktls()
	if ssl then
		local cipher = ssl:getCipherInfo()
		if h2_banned_ciphers[cipher.name] then
			h2_error.errors.INADEQUATE_SECURITY("bad cipher: " .. cipher.name)
		end
	end
	if conn_type == "client" then
		local ok, err = socket:xwrite(preface, "f", timeout)
		if ok == nil then return nil, err end
	elseif conn_type == "server" then
		local ok, err = socket_has_preface(socket, false, timeout)
		if ok == nil then
			return nil, err
		end
		if not ok then
			h2_error.errors.PROTOCOL_ERROR("invalid connection preface. not an http2 client?")
		end
	else
		error('invalid connection type. must be "client" or "server"')
	end

	settings = settings or {}

	local self = setmetatable({
		socket = socket;
		type = conn_type;
		version = 2; -- for compat with h1_connection

		streams = setmetatable({}, {__mode="kv"});
		stream0 = nil; -- store separately with a strong reference
		need_continuation = nil; -- stream
		cq = cq;
		highest_odd_stream = -1;
		highest_even_stream = -2;
		recv_goaway_lowest = nil;
		recv_goaway = cc.new();
		new_streams = new_fifo();
		new_streams_cond = cc.new();
		peer_settings = default_settings;
		peer_settings_cond = cc.new(); -- signaled when the peer has changed their settings
		acked_settings = default_settings;
		send_settings = {n = 0};
		send_settings_ack_cond = cc.new(); -- for when server ACKs our settings
		send_settings_acked = 0;
		peer_flow_credits = 65535; -- 5.2.1
		peer_flow_credits_increase = cc.new();
		encoding_context = nil;
		decoding_context = nil;
		pongs = {}; -- pending pings we've sent. keyed by opaque 8 byte payload
	}, connection_mt)
	self:new_stream(0)
	self.encoding_context = hpack.new(default_settings[0x1])
	self.decoding_context = hpack.new(default_settings[0x1])
	self.cq:wrap(connection_main_loop, self)

	do -- send settings frame + wait for reply to complete connection
		local ok, err = self:settings(settings, deadline and (deadline-monotime()))
		if not ok then
			return nil, err
		end
	end

	return self
end

function connection_methods:pollfd()
	return self.socket:pollfd()
end

function connection_methods:events()
	return self.socket:events()
end

function connection_methods:timeout()
	if not self:empty() then
		return 0
	end
end

function connection_main_loop(self)
	while not self.socket:eof("r") do
		local typ, flag, streamid, payload = self:read_http2_frame()
		if typ == nil then
			if flag == nil then -- EOF
				break
			else
				error(flag)
			end
		end
		local handler = h2_stream.frame_handlers[typ]
		-- http2 spec section 4.1:
		-- Implementations MUST ignore and discard any frame that has a type that is unknown.
		if handler then
			local stream = self.streams[streamid]
			if stream == nil then
				if xor(streamid % 2 == 1, self.type == "client") then
					h2_error.errors.PROTOCOL_ERROR("Streams initiated by a client MUST use odd-numbered stream identifiers; those initiated by the server MUST use even-numbered stream identifiers")
				end
				-- TODO: check MAX_CONCURRENT_STREAMS
				stream = self:new_stream(streamid)
				self.new_streams:push(stream)
				self.new_streams_cond:signal(1)
			end
			local ok, err = handler(stream, flag, payload)
			if not ok then
				if h2_error.is(err) and err.stream_error then
					if not stream:write_rst_stream(err.code) then
						error(err)
					end
				else -- connection error or unknown error
					error(err)
				end
			end
		end
	end
	return true
end

local function handle_step_return(self, step_ok, last_err, errno)
	if step_ok then
		return true
	else
		if not self.socket:eof("w") then
			local code, message
			if step_ok then
				code = h2_error.errors.NO_ERROR.code
			elseif h2_error.is(last_err) then
				code = last_err.code
				message = last_err.message
			else
				code = h2_error.errors.INTERNAL_ERROR.code
			end
			-- ignore write failure here; there's nothing that can be done
			self:write_goaway_frame(nil, code, message)
		end
		self:shutdown()
		return nil, last_err, errno
	end
end

function connection_methods:empty()
	return self.cq:empty()
end

function connection_methods:step(...)
	if self:empty() then
		return handle_step_return(self, false, ce.EPIPE)
	else
		return handle_step_return(self, self.cq:step(...))
	end
end

function connection_methods:loop(...)
	if self:empty() then
		return handle_step_return(self, false, ce.EPIPE)
	else
		return handle_step_return(self, self.cq:loop(...))
	end
end

function connection_methods:checktls()
	return self.socket:checktls()
end

function connection_methods:localname()
	return self.socket:localname()
end

function connection_methods:peername()
	return self.socket:peername()
end

function connection_methods:shutdown()
	local ok, err = self:write_goaway_frame(nil, h2_error.errors.NO_ERROR.code, "connection closed")
	if not ok and err == ce.EPIPE then
		-- other end already closed
		ok, err = true, nil
	end
	for _, stream in pairs(self.streams) do
		stream:shutdown()
	end
	self.socket:shutdown("r")
	return ok, err
end

function connection_methods:close()
	local ok, err = self:shutdown()
	cqueues.poll()
	cqueues.poll()
	self.socket:close()
	return ok, err
end

function connection_methods:new_stream(id)
	if id then
		assert(id % 1 == 0)
	else
		if self.recv_goaway_lowest then
			h2_error.errors.PROTOCOL_ERROR("Receivers of a GOAWAY frame MUST NOT open additional streams on the connection")
		end
		if self.type == "client" then
			-- Pick next free odd number
			id = self.highest_odd_stream + 2
		else
			-- Pick next free odd number
			id = self.highest_even_stream + 2
		end
		-- TODO: check MAX_CONCURRENT_STREAMS
	end
	assert(self.streams[id] == nil, "stream id already in use")
	assert(id < 2^32, "stream id too large")
	if id % 2 == 0 then
		assert(id > self.highest_even_stream, "stream id too small")
		self.highest_even_stream = id
	else
		assert(id > self.highest_odd_stream, "stream id too small")
		self.highest_odd_stream = id
	end
	local stream = h2_stream.new(self, id)
	if id == 0 then
		self.stream0 = stream
	else
		-- Add dependency on stream 0. http2 spec, 5.3.1
		self.stream0:reprioritise(stream)
	end
	self.streams[id] = stream
	return stream
end

-- this function *should never throw*
function connection_methods:get_next_incoming_stream(timeout)
	local deadline = timeout and (monotime()+timeout)
	while self.new_streams:length() == 0 do
		if self.recv_goaway_lowest then
			-- TODO? clarification required: can the sender of a GOAWAY subsequently start streams?
			-- (with a lower stream id than they sent in the GOAWAY)
			-- For now, assume not.
			return nil, ce.EPIPE
		end
		local which = cqueues.poll(self, self.new_streams_cond, self.recv_goaway, timeout)
		if which == self then
			local ok, err, errno = self:step(0)
			if not ok then
				return nil, err, errno
			end
		elseif which == timeout then
			return nil, ce.ETIMEDOUT
		end
		timeout = deadline and (deadline-monotime())
	end

	local stream = self.new_streams:pop()
	return stream
end

-- On success, returns type, flags, stream id and payload
-- On timeout, returns nil, ETIMEDOUT -- safe to retry
-- If the socket has been shutdown for reading, and there is no data left unread, returns EPIPE
-- Will raise an error on other errors, or if the frame is invalid
function connection_methods:read_http2_frame(timeout)
	local deadline = timeout and (monotime()+timeout)
	local frame_header, err, errno = self.socket:xread(9, timeout)
	if frame_header == nil then
		if err == ce.ETIMEDOUT then
			return nil, err
		elseif err == nil --[[EPIPE]] and self.socket:eof("r") then
			return nil
		else
			return nil, err, errno
		end
	end
	local size, typ, flags, streamid = sunpack(">I3 B B I4", frame_header)
	if size > self.acked_settings[0x5] then
		return nil, h2_error.errors.FRAME_SIZE_ERROR:new_traceback("frame too large")
	end
	-- reserved bit MUST be ignored by receivers
	streamid = band(streamid, 0x7fffffff)
	local payload, err2, errno2 = self.socket:xread(size, deadline and (deadline-monotime()))
	if payload == nil then
		if err2 == ce.ETIMEDOUT then
			-- put frame header back into socket so a retry will work
			local ok, errno3 = self.socket:unget(frame_header)
			if not ok then
				local err3 = onerror(self.socket, "unget", errno3, 2)
				error(err3)
			end
			return nil, err2, errno2
		else
			return nil, err2, errno2
		end
	end
	return typ, flags, streamid, payload
end

-- If this times out, it was the flushing; not the write itself
-- hence it's not always total failure.
-- It's up to the caller to take some action (e.g. closing) rather than doing it here
-- TODO: distinguish between nothing sent and partially sent?
function connection_methods:write_http2_frame(typ, flags, streamid, payload, timeout)
	local deadline = timeout and (monotime()+timeout)
	if #payload > self.peer_settings[0x5] then
		return nil, h2_error.errors.FRAME_SIZE_ERROR:new_traceback("frame too large")
	end
	local header = spack(">I3 B B I4", #payload, typ, flags, streamid)
	local ok, err, errno = self.socket:xwrite(header, "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return self.socket:xwrite(payload, "n", deadline and (deadline-monotime()))
end

function connection_methods:ping(timeout)
	local deadline = timeout and (monotime()+timeout)
	local payload
	-- generate a random, unique payload
	repeat -- keep generating until we don't have a collision
		payload = rand.bytes(8)
	until self.pongs[payload] == nil
	local cond = cc.new()
	self.pongs[payload] = cond
	assert(self.stream0:write_ping_frame(false, payload, timeout))
	while self.pongs[payload] do
		timeout = deadline and (deadline-monotime())
		local which = cqueues.poll(self, cond, timeout)
		if which == self then
			local ok, err, errno = self:step(0)
			if not ok then
				return nil, err, errno
			end
		elseif which == timeout then
			return nil, ce.ETIMEDOUT
		end
	end
	return true
end

function connection_methods:write_window_update(...)
	return self.stream0:write_window_update(...)
end

function connection_methods:write_goaway_frame(last_stream_id, err_code, debug_msg)
	if last_stream_id == nil then
		last_stream_id = math.max(self.highest_odd_stream, self.highest_even_stream)
	end
	return self.stream0:write_goaway_frame(last_stream_id, err_code, debug_msg)
end

function connection_methods:set_peer_settings(peer_settings)
	self.peer_settings = merge_settings(peer_settings, self.peer_settings)
	self.peer_settings_cond:signal()
end

function connection_methods:ack_settings()
	local n = self.send_settings_acked + 1
	self.send_settings_acked = n
	local acked_settings = self.send_settings[n]
	self.send_settings[n] = nil
	self.acked_settings = merge_settings(acked_settings, self.acked_settings)
	self.send_settings_ack_cond:signal(1)
end

function connection_methods:settings(tbl, timeout)
	local deadline = timeout and (monotime()+timeout)
	local n = self.send_settings.n + 1
	self.send_settings.n = n
	self.send_settings[n] = tbl
	local ok, err, errno = self.stream0:write_settings_frame(false, tbl, timeout)
	if not ok then
		return nil, err, errno
	end
	-- Now wait for ACK
	while self.send_settings_acked < n do
		timeout = deadline and (deadline-monotime())
		local which = cqueues.poll(self, self.send_settings_ack_cond, timeout)
		if which == self then
			local ok2, err2, errno2 = self:step(0)
			if not ok2 then
				return nil, err2, errno2
			end
		elseif which ~= self.send_settings_ack_cond then
			self:write_goaway_frame(nil, h2_error.errors.SETTINGS_TIMEOUT.code, "timeout exceeded")
			return nil, ce.ETIMEDOUT
		end
	end
	return true
end

return {
	preface = preface;
	socket_has_preface = socket_has_preface;
	new = new_connection;
	methods = connection_methods;
	mt = connection_mt;
}
