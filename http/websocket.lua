--[[
WebSocket module

Specified in RFC-6455

Design criteria:
  - Client API must work without an event loop
  - Borrow from the Browser Javascript WebSocket API when sensible
  - server-side API should mirror client-side API

This code is partially based on MIT/X11 code Copyright (C) 2012 Florian Zeitz
]]

local basexx = require "basexx"
local spack = string.pack or require "compat53.string".pack
local sunpack = string.unpack or require "compat53.string".unpack
local unpack = table.unpack or unpack -- luacheck: ignore 113
local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ce = require "cqueues.errno"
local uri_patts = require "lpeg_patterns.uri"
local rand = require "openssl.rand"
local digest = require "openssl.digest"
local bit = require "http.bit"
local http_request = require "http.request"

local websocket_methods = {
	-- Max seconds to wait after sending close frame until closing connection
	close_timeout = 3;
}

local websocket_mt = {
	__name = "http.websocket";
	__index = websocket_methods;
}

local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- a nonce consisting of a randomly selected 16-byte value that has been base64-encoded
local function new_key()
	return basexx.to_base64(rand.bytes(16))
end

local function base64_sha1(str)
	return basexx.to_base64(digest.new("sha1"):final(str))
end

-- trim12 from http://lua-users.org/wiki/StringTrim
local function trim(s)
	local from = s:match"^%s*()"
	return from > #s and "" or s:match(".*%S", from)
end

-- XORs the string `str` with a 32bit key
local function apply_mask(str, key)
	assert(#key == 4)
	local data = {}
	for i = 1, #str do
		local key_index = (i-1)%4 + 1
		data[i] = string.char(bit.bxor(key[key_index], str:byte(i)))
	end
	return table.concat(data)
end

local function build_frame(desc)
	local data = desc.data or ""

	assert(desc.opcode and desc.opcode >= 0 and desc.opcode <= 0xF, "Invalid WebSocket opcode")
	if desc.opcode >= 0x8 then
		-- RFC 6455 5.5
		assert(#data <= 125, "WebSocket control frames MUST have a payload length of 125 bytes or less.")
	end

	local b1 = bit.bor(desc.opcode,
		desc.FIN and 0x80 or 0,
		desc.RSV1 and 0x40 or 0,
		desc.RSV2 and 0x20 or 0,
		desc.RSV3 and 0x10 or 0)

	local b2 = #data
	local length_extra
	if b2 <= 125 then -- 7-bit length
		length_extra = ""
	elseif b2 <= 0xFFFF then -- 2-byte length
		b2 = 126
		length_extra = spack(">I2", #data)
	else -- 8-byte length
		b2 = 127
		length_extra = spack(">I8", #data)
	end

	local key = ""
	if desc.MASK then
		local key_a = desc.key
		if key_a then
			key = string.char(unpack(key_a, 1, 4))
		else
			key = rand.bytes(4)
			key_a = {key:byte(1,4)}
		end
		b2 = bit.bor(b2, 0x80)
		data = apply_mask(data, key_a)
	end

	return string.char(b1, b2) .. length_extra .. key .. data
end

local function build_close(code, message, mask)
	local data = spack(">I2", code)
	if message then
		assert(#message<=123, "Close reason must be <=123 bytes")
		data = data .. message
	end
	return {
		opcode = 0x8;
		FIN = true;
		MASK = mask;
		data = data;
	}
end

local function read_frame(sock, deadline)
	local frame do
		local first_2, err, errno = sock:xread(2, deadline and (deadline-monotime()))
		if not first_2 then
			return nil, err, errno
		end
		local byte1, byte2 = first_2:byte(1, 2)
		frame = {
			FIN = bit.band(byte1, 0x80) ~= 0;
			RSV1 = bit.band(byte1, 0x40) ~= 0;
			RSV2 = bit.band(byte1, 0x20) ~= 0;
			RSV3 = bit.band(byte1, 0x10) ~= 0;
			opcode = bit.band(byte1, 0x0F);

			MASK = bit.band(byte2, 0x80) ~= 0;
			length = bit.band(byte2, 0x7F);

			data = nil;
		}
	end

	if frame.length == 126 then
		local length, err, errno = sock:xread(2, deadline and (deadline-monotime()))
		if not length then
			return nil, err, errno
		end
		frame.length = sunpack(">I2", length)
	elseif frame.length == 127 then
		local length, err, errno = sock:xread(8, deadline and (deadline-monotime()))
		if not length then
			return nil, err, errno
		end
		frame.length = sunpack(">I8", length)
	end

	if frame.MASK then
		local key, err, errno = sock:xread(4, deadline and (deadline-monotime()))
		if not key then
			return nil, err, errno
		end
		frame.key = { key:byte(1, 4) }
	end

	do
		local data, err, errno = sock:xread(frame.length, deadline and (deadline-monotime()))
		if data == nil then
			return nil, err, errno
		end

		if frame.MASK then
			frame.data = apply_mask(data, frame.key)
		else
			frame.data = data
		end
	end

	return frame
end

local function parse_close(data)
	local code, message
	if #data >= 2 then
		code = sunpack(">I2", data)
		if #data > 2 then
			message = data:sub(3)
		end
	end
	return code, message
end

function websocket_methods:send_frame(frame, timeout)
	local ok, err, errno = self.socket:xwrite(build_frame(frame), "n", timeout)
	if not ok then
		return nil, err, errno
	end
	if frame.opcode == 0x8 then
		self.readyState = 2
	end
	return true
end

function websocket_methods:send(data, opcode)
	if self.readyState >= 2 then
		return nil, "WebSocket closed, unable to send data", ce.EPIPE
	end
	assert(type(data) == "string")
	if opcode == "text" or opcode == nil then
		opcode = 0x1
	elseif opcode == "binary" then
		opcode = 0x2;
	end
	return self:send_frame({
		FIN = true;
		--[[ RFC 6455
		5.1: A server MUST NOT mask any frames that it sends to the client
		6.1.5: If the data is being sent by the client, the frame(s) MUST be masked]]
		MASK = self.type == "client";
		opcode = opcode;
		data = data;
	})
end

local function close_helper(self, code, reason, deadline)
	if self.readyState == 3 then
		return nil, ce.strerror(ce.EPIPE), ce.EPIPE
	end

	if self.readyState < 2 then
		local close_frame = build_close(code, reason, true)
		-- ignore failure
		self:send_frame(close_frame, deadline and deadline-monotime())
	end

	-- Do not close socket straight away, wait for acknowledgement from server
	local read_deadline = monotime() + self.close_timeout
	if deadline then
		read_deadline = math.min(read_deadline, deadline)
	end
	while not self.got_close_code do
		if not self:read(read_deadline-monotime()) then
			break
		end
	end

	self.socket:shutdown()
	cqueues.poll()
	cqueues.poll()
	self.socket:close()

	self.readyState = 3

	return nil, reason, ce.ENOMSG
end

function websocket_methods:close(code, reason, timeout)
	local deadline = timeout and (monotime()+timeout)
	code = code or 1000
	close_helper(self, code, reason, deadline)
	return true
end

function websocket_methods:read(timeout)
	local deadline = timeout and (monotime()+timeout)
	local databuffer, databuffer_type
	while true do
		local frame, err, errno = read_frame(self.socket, deadline and (deadline-monotime()))
		if frame == nil then
			return nil, err, errno
		end

		-- Error cases
		if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
			return close_helper(self, 1002, "Reserved bits not zero", deadline)
		end

		if frame.opcode < 0x8 then
			if frame.opcode == 0x0 then -- Continuation frames
				if not databuffer then
					return close_helper(self, 1002, "Unexpected continuation frame", deadline)
				end
				databuffer[#databuffer+1] = frame.data
			elseif frame.opcode == 0x1 or frame.opcode == 0x2 then -- Text or Binary frame
				if databuffer then
					return close_helper(self, 1002, "Continuation frame expected", deadline)
				end
				databuffer = { frame.data }
				if frame.opcode == 0x1 then
					databuffer_type = "text"
				else
					databuffer_type = "binary"
				end
			else
				return close_helper(self, 1002, "Reserved opcode", deadline)
			end
			if frame.FIN then
				return table.concat(databuffer), databuffer_type
			end
		else -- Control frame
			if frame.length > 125 then -- Control frame with too much payload
				return close_helper(self, 1002, "Payload too large", deadline)
			elseif not frame.FIN then -- Fragmented control frame
				return close_helper(self, 1002, "Fragmented control frame", deadline)
			end
			if frame.opcode == 0x8 then -- Close request
				if frame.length == 1 then
					return close_helper(self, 1002, "Close frame with payload, but too short for status code", deadline)
				end
				local status_code, message = parse_close(frame.data)
				if status_code == nil then
					--[[ RFC 6455 7.4.1
					1005 is a reserved value and MUST NOT be set as a status code in a
					Close control frame by an endpoint.  It is designated for use in
					applications expecting a status code to indicate that no status
					code was actually present.]]
					status_code = 1005
				elseif status_code < 1000 then
					return close_helper(self, 1002, "Closed with invalid status code", deadline)
				elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
					return close_helper(self, 1002, "Closed with reserved status code", deadline)
				end
				self.got_close_code = status_code
				self.got_close_message = message
				return close_helper(self, status_code, message, deadline)
			elseif frame.opcode == 0x9 then -- Ping frame
				frame.opcode = 0xA
				--[[ RFC 6455
				5.1: A server MUST NOT mask any frames that it sends to the client
				6.1.5: If the data is being sent by the client, the frame(s) MUST be masked]]
				frame.MASK = self.type == "client";
				if not self:send_frame(frame, deadline and (deadline-monotime())) then
					return close_helper(self, 1002, "Pong failed", deadline)
				end
			elseif frame.opcode == 0xA then -- luacheck: ignore 542
				-- Received unexpected pong frame
			else
				return close_helper(self, 1002, "Reserved opcode", deadline)
			end
		end
	end
end

function websocket_methods:each()
	return function(self) -- luacheck: ignore 432
		return self:read()
	end, self
end

local function new(type)
	assert(type == "client")
	local self = setmetatable({
		socket = nil;
		type = type;
		readyState = 0;
		got_close_code = nil;
		got_close_reason = nil;
		key = nil;
		protocols = nil;
		request = nil;
	}, websocket_mt)
	return self
end

local function new_from_uri_t(uri_t, protocols)
	local scheme = assert(uri_t.scheme, "URI missing scheme")
	assert(scheme == "ws" or scheme == "wss", "scheme not websocket")
	local self = new("client")
	self.request = http_request.new_from_uri_t(uri_t)
	self.request.version = 1.1
	self.request.headers:append("connection", "upgrade")
	self.request.headers:append("upgrade", "websocket")
	self.key = new_key()
	self.request.headers:append("sec-websocket-key", self.key, true)
	self.request.headers:append("sec-websocket-version", "13")
	if protocols then
		--[[ The request MAY include a header field with the name
        Sec-WebSocket-Protocol. If present, this value indicates one
        or more comma-separated subprotocol the client wishes to speak,
        ordered by preference. The elements that comprise this value
        MUST be non-empty strings with characters in the range U+0021 to
        U+007E not including separator characters as defined in
        [RFC2616] and MUST all be unique strings.]]
        -- TODO: protocol validation
		self.protocols = protocols
		self.request.headers:append("sec-websocket-protocol", table.concat(protocols, ","))
	end
	return self
end

local function new_from_uri(uri, ...)
	local uri_t = assert(uri_patts.uri:match(uri), "invalid URI")
	return new_from_uri_t(uri_t, ...)
end

local function handle_websocket_response(self, headers, stream)
	assert(self.type == "client" and self.readyState == 0)

	if stream.connection.version < 1 or stream.connection.version >= 2 then
		return nil, "websockets only supported with HTTP 1.x", ce.EINVAL
	end

	--[[ If the status code received from the server is not 101, the
	client handles the response per HTTP [RFC2616] procedures.  In
	particular, the client might perform authentication if it
	receives a 401 status code; the server might redirect the client
	using a 3xx status code (but clients are not required to follow
	them), etc.]]
	if headers:get(":status") ~= "101" then
		return nil, "status code not 101", ce.EINVAL
	end

	--[[ If the response lacks an Upgrade header field or the Upgrade
	header field contains a value that is not an ASCII case-
	insensitive match for the value "websocket", the client MUST
	Fail the WebSocket Connection]]
	local upgrade = headers:get("upgrade")
	if not upgrade or upgrade:lower() ~= "websocket" then
		return nil, "upgrade header not websocket", ce.EINVAL
	end

	--[[ If the response lacks a Connection header field or the
	Connection header field doesn't contain a token that is an
	ASCII case-insensitive match for the value "Upgrade", the client
	MUST Fail the WebSocket Connection]]
	local has_connection_upgrade = false
	local connection_header = headers:get_split_as_sequence("connection")
	for i=1, connection_header.n do
		if connection_header[i]:lower() == "upgrade" then
			has_connection_upgrade = true
			break
		end
	end
	if not has_connection_upgrade then
		return nil, "connection header doesn't contain upgrade", ce.EINVAL
	end

	--[[ If the response lacks a Sec-WebSocket-Accept header field or
	the Sec-WebSocket-Accept contains a value other than the
	base64-encoded SHA-1 of the concatenation of the Sec-WebSocket-
	Key (as a string, not base64-decoded) with the string "258EAFA5-
	E914-47DA-95CA-C5AB0DC85B11" but ignoring any leading and
	trailing whitespace, the client MUST Fail the WebSocket Connection]]
	local sec_websocket_accept = headers:get("sec-websocket-accept")
	if sec_websocket_accept == nil or
		trim(sec_websocket_accept) ~= base64_sha1(self.key .. magic)
	then
		return nil, "sec-websocket-accept header incorrect", ce.EINVAL
	end

	--[[ If the response includes a Sec-WebSocket-Extensions header field and
	this header field indicates the use of an extension that was not present
	in the client's handshake (the server has indicated an extension not
	requested by the client), the client MUST Fail the WebSocket Connection]]
	-- For now, we don't support any extensions
	if headers:has("sec-websocket-extensions") then
		return nil, "extensions not supported", ce.EINVAL
	end

	--[[ If the response includes a Sec-WebSocket-Protocol header field and
	this header field indicates the use of a subprotocol that was not present
	in the client's handshake (the server has indicated a subprotocol not
	requested by the client), the client MUST Fail the WebSocket Connection]]
	if headers:has("sec-websocket-protocol") then
		local has_matching_protocol = false
		if self.protocols then
			local swps = headers:get_split_as_sequence("sec-websocket-protocol")
			for i=1, swps.n do
				local p1 = swps[i]:lower()
				for _, p2 in ipairs(self.protocols) do
					if p1 == p2 then
						has_matching_protocol = true
						break
					end
				end
				if has_matching_protocol then
					break
				end
			end
		end
		if not has_matching_protocol then
			return nil, "unexpected protocol", ce.EINVAL
		end
	end

	-- Success!
	self.socket = assert(stream.connection:take_socket())
	self.readyState = 1

	return true
end

function websocket_methods:connect(timeout)
	assert(self.type == "client" and self.readyState == 0)
	local headers, stream, errno = self.request:go(timeout)
	if not headers then
		return nil, stream, errno
	end
	return handle_websocket_response(self, headers, stream)
end

return {
	new_from_uri_t = new_from_uri_t;
	new_from_uri = new_from_uri;

	build_frame = build_frame;
	read_frame = read_frame;
	build_close = build_close;
	parse_close = parse_close;
}
