--[[
Uses code from prosody's net/websocket
Some portions Copyright (C) 2012 Florian Zeitz
]]

local basexx = require "basexx"
local spack = string.pack or require "compat53.string".pack
local sunpack = string.unpack or require "compat53.string".unpack
local unpack = table.unpack or unpack -- luacheck: ignore 113
local cqueues = require "cqueues"
local monotime = cqueues.monotime
local uri_patts = require "lpeg_patterns.uri"
local rand = require "openssl.rand"
local digest = require "openssl.digest"
local new_headers = require "http.headers".new
local bit = require "http.bit"
local http_request = require "http.request"

-- Seconds to wait after sending close frame until closing connection.
local close_timeout = 3

-- a nonce consisting of a randomly selected 16-byte value that has been base64-encoded
local function new_key()
	return basexx.to_base64(rand.bytes(16))
end

local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function base64_sha1(str)
	return basexx.to_base64(digest.new("sha1"):final(str))
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
	return build_frame {
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

local function read_loop(sock, on_data, on_close)
	local code, reason = 1000, nil
	local databuffer, databuffer_type
	while true do
		local frame, err, errno = read_frame(sock)
		if frame == nil then
			return nil, err, errno
		end

		-- Error cases
		if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
			code, reason = 1002, "Reserved bits not zero"
			break
		end

		if frame.opcode < 0x8 then
			if frame.opcode == 0x0 then -- Continuation frames
				if not databuffer then
					code, reason = 1002, "Unexpected continuation frame"
					break
				end
				databuffer[#databuffer+1] = frame.data
			elseif frame.opcode == 0x1 or frame.opcode == 0x2 then -- Text or Binary frame
				if databuffer then
					code, reason = 1002, "Continuation frame expected"
					break
				end
				databuffer = { frame.data }
				if frame.opcode == 0x1 then
					databuffer_type = "text"
				else
					databuffer_type = "binary"
				end
			else
				code, reason = 1002, "Reserved opcode"
				break
			end
			if frame.FIN then
				on_data(databuffer_type, table.concat(databuffer))
				databuffer, databuffer_type = nil, nil
			end
		else -- Control frame
			if frame.length > 125 then -- Control frame with too much payload
				code, reason = 1002, "Payload too large"
				break
			elseif not frame.FIN then -- Fragmented control frame
				code, reason = 1002, "Fragmented control frame"
				break
			end
			if frame.opcode == 0x8 then -- Close request
				if frame.length == 1 then
					code, reason = 1002, "Close frame with payload, but too short for status code"
					break
				end
				local status_code, message = parse_close(frame.data)
				if status_code == nil then
					--[[ RFC 6455 7.4.1
					1005 is a reserved value and MUST NOT be set as a status code in a
					Close control frame by an endpoint.  It is designated for use in
					applications expecting a status code to indicate that no status
					code was actually present.
					]]
					status_code = 1005
				elseif status_code < 1000 then
					code, reason = 1002, "Closed with invalid status code"
					break
				elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
					code, reason = 1002, "Closed with reserved status code"
					break
				end
				code, reason = 1000, nil
				on_close(status_code, message)
				break
			elseif frame.opcode == 0x9 then -- Ping frame
				frame.opcode = 0xA
				frame.MASK = true; -- RFC 6455 6.1.5: If the data is being sent by the client, the frame(s) MUST be masked
				sock:write(build_frame(frame))
			elseif frame.opcode == 0xA then -- luacheck: ignore 542
				-- Received unexpected pong frame
			else
				code, reason = 1002, "Reserved opcode"
				break
			end
		end
	end

	if sock:xwrite(build_close(code, reason, true), "n") then
		-- Do not close socket straight away, wait for acknowledgement from server.
		cqueues.poll(sock, close_timeout)
	end

	sock:close()

	return true
end


local function new_from_uri_t(uri_t, protocols)
	local scheme = assert(uri_t.scheme, "URI missing scheme")
	assert(scheme == "ws" or scheme == "wss", "scheme not websocket")
	local headers = new_headers()
	headers:append("connection", "upgrade")
	headers:append("upgrade", "websocket")
	headers:append("sec-websocket-key", new_key(), true)
	if protocols then
		--[[ The request MAY include a header field with the name
        |Sec-WebSocket-Protocol|.  If present, this value indicates one
        or more comma-separated subprotocol the client wishes to speak,
        ordered by preference.  The elements that comprise this value
        MUST be non-empty strings with characters in the range U+0021 to
        U+007E not including separator characters as defined in
        [RFC2616] and MUST all be unique strings. ]]
        -- TODO: protocol validation
		headers:append("sec-websocket-protocol", table.concat(protocols, ","))
	end
	headers:append("sec-websocket-version", "13")
	local req = http_request.new_from_uri_t(uri_t, headers)
	return req
end

local function new_from_uri(uri, ...)
	local uri_t = assert(uri_patts.uri:match(uri), "invalid URI")
	uri_t.scheme = uri_t.scheme or "ws" -- default to ws
	return new_from_uri_t(uri_t, ...)
end

do
	local function has(list, val)
		for i=1, list.n do
			if list[i]:lower() == val then
				return true
			end
		end
		return false
	end
	local function has_any(list1, list2)
		for i=1, list2.n do
			if has(list1, list2[i]) then
				return true
			end
		end
		return false
	end

	-- trim12 from http://lua-users.org/wiki/StringTrim
	local function trim(s)
		local from = s:match"^%s*()"
		return from > #s and "" or s:match(".*%S", from)
	end

	local req = new_from_uri("ws://echo.websocket.org")
	local stream = req:new_stream()
	assert(stream:write_headers(req.headers, false))
	local headers = assert(stream:get_headers())
	-- TODO: redirects
	if headers:get(":status") == "101"
		--[[ If the response lacks an |Upgrade| header field or the |Upgrade|
		header field contains a value that is not an ASCII case-
		insensitive match for the value "websocket", the client MUST
		_Fail the WebSocket Connection_.]]
		and headers:get("upgrade"):lower() == "websocket"
		--[[ If the response lacks a |Connection| header field or the
		|Connection| header field doesn't contain a token that is an
		ASCII case-insensitive match for the value "Upgrade", the client
		MUST _Fail the WebSocket Connection_.]]
		and has(headers:get_split_as_sequence("connection"), "upgrade")
		--[[ If the response lacks a |Sec-WebSocket-Accept| header field or
		the |Sec-WebSocket-Accept| contains a value other than the
		base64-encoded SHA-1 of the concatenation of the |Sec-WebSocket-
		Key| (as a string, not base64-decoded) with the string "258EAFA5-
		E914-47DA-95CA-C5AB0DC85B11" but ignoring any leading and
		trailing whitespace, the client MUST _Fail the WebSocket
		Connection_.]]
		and trim(headers:get("sec-websocket-accept")) == base64_sha1(trim(req.headers:get("sec-websocket-key"))..magic)
		--[[ If the response includes a |Sec-WebSocket-Extensions| header
		field and this header field indicates the use of an extension
		that was not present in the client's handshake (the server has
		indicated an extension not requested by the client), the client
		MUST _Fail the WebSocket Connection_.]]
		-- For now, we don't support any extensions
		and headers:get_split_as_sequence("sec-websocket-extensions").n == 0
		--[[ If the response includes a |Sec-WebSocket-Protocol| header field
		and this header field indicates the use of a subprotocol that was
		not present in the client's handshake (the server has indicated a
		subprotocol not requested by the client), the client MUST _Fail
		the WebSocket Connection_.]]
		and (not headers:has("sec-websocket-protocol")
			or has_any(headers:get_split_as_sequence("sec-websocket-protocol"), req.headers:get_split_as_sequence("sec-websocket-protocol")))
	then
		-- Success!
		print(stream)
		local sock = stream.connection:take_socket()
		print(sock)

		local function send(data, opcode)
			-- if self.readyState < 1 then
			-- 	return nil, "WebSocket not open yet, unable to send data."
			-- elseif self.readyState >= 2 then
			-- 	return nil, "WebSocket closed, unable to send data."
			-- end
			if opcode == "text" or opcode == nil then
				opcode = 0x1
			elseif opcode == "binary" then
				opcode = 0x2;
			end
			return sock:xwrite(build_frame{
				FIN = true;
				MASK = true; -- RFC 6455 6.1.5: If the data is being sent by the client, the frame(s) MUST be masked
				opcode = opcode;
				data = tostring(data);
			}, "n")
		end


		-- function websocket_methods:close(code, reason)
		-- 	if self.readyState < 2 then
		-- 		code = code or 1000;
		-- 		log("debug", "closing WebSocket with code %i: %s" , code , tostring(reason));
		-- 		self.readyState = 2;
		-- 		local handler = self.handler;
		-- 		handler:write(frames.build_close(code, reason, true));
		-- 		-- Do not close socket straight away, wait for acknowledgement from server.
		-- 		self.close_timer = timer.add_task(close_timeout, close_timeout_cb, self);
		-- 	elseif self.readyState == 2 then
		-- 		log("debug", "tried to close a closing WebSocket, closing the raw socket.");
		-- 		-- Stop timer
		-- 		if self.close_timer then
		-- 			timer.stop(self.close_timer);
		-- 			self.close_timer = nil;
		-- 		end
		-- 		local handler = self.handler;
		-- 		handler:close();
		-- 	else
		-- 		log("debug", "tried to close a closed WebSocket, ignoring.");
		-- 	end
		-- end

		local new_fifo = require "fifo"
		local cc = require "cqueues.condition"
		local cond = cc.new()
		local q = new_fifo()
		q:setempty(function()
			cond:wait()
			return q:pop()
		end)
		local cq = cqueues.new()
		cq:wrap(function()
			local ok, err = read_loop(sock, function(type, data)
				q:push({type, data})
				cond:signal(1)
			end, print)
			if not ok then
				error(err)
			end
		end)
		local function get_next(f)
			local ob = f:pop()
			local type, data = ob[1], ob[2]
			return type, data
		end
		local function each()
			return get_next, q
		end


		cq:wrap(function()
			for type, data in each() do
				print("QWEWE", type, data)
			end
		end)
		cq:wrap(function()
			send("foo")
			cqueues.sleep(1)
			send("bar")
			send("bar", "binary")
		end)
		assert(cq:loop())
	else
		print("FAIL")
		headers:dump()
	end
end

return {
	new_from_uri_t = new_from_uri_t;
	new_from_uri = new_from_uri;
}


