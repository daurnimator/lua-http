local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local new_fifo = require "fifo"
local band = require "http.bit".band
local bor = require "http.bit".bor
local h2_errors = require "http.h2_error".errors
local stream_common = require "http.stream_common"
local assert = require "compat53.module".assert
local spack = string.pack or require "compat53.string".pack
local sunpack = string.unpack or require "compat53.string".unpack
local unpack = table.unpack or unpack -- luacheck: ignore 113

local function xor(a, b)
	return (a and b) or not (a or b)
end

local MAX_HEADER_BUFFER_SIZE = 400*1024 -- 400 KB is max size in h2o

local frame_handlers = {}

local stream_methods = {}
for k, v in pairs(stream_common.methods) do
	stream_methods[k] = v
end
local stream_mt = {
	__name = "http.h2_stream";
	__index = stream_methods;
}

function stream_mt:__tostring()
	local dependee_list = {}
	for s in pairs(self.dependees) do
		dependee_list[#dependee_list+1] = string.format("%d", s.id)
	end
	table.sort(dependee_list)
	dependee_list = table.concat(dependee_list, ",")
	return string.format("http.h2_stream{connection=%s;id=%d;state=%q;parent=%s;dependees={%s}}",
		tostring(self.connection), self.id, self.state,
		(self.parent and tostring(self.parent.id) or "nil"), dependee_list)
end

local function new_stream(connection, id)
	assert(type(id) == "number" and id >= 0 and id <= 0x7fffffff, "invalid stream id")
	local self = setmetatable({
		connection = connection;
		type = connection.type;

		state = "idle";

		id = id;
		peer_flow_credits = id ~= 0 and connection.peer_settings[0x4];
		peer_flow_credits_increase = cc.new();
		parent = nil;
		dependees = setmetatable({}, {__mode="kv"});
		weight = 16; -- http2 spec, section 5.3.5

		rst_stream_error = nil;

		stats_sent = 0;

		recv_headers_fifo = new_fifo();
		recv_headers_cond = cc.new();
		-- Used as storage over CONTINUATION frames
		recv_headers_padding = nil;
		recv_headers_buffer = nil;
		recv_headers_buffer_items = nil;
		recv_headers_buffer_length = nil;

		chunk_fifo = new_fifo();
		chunk_cond = cc.new();
	}, stream_mt)
	return self
end

local valid_states = {
	["idle"] = true; -- initial
	["open"] = true; -- have sent or received headers; haven't sent body yet
	["half closed (local)"] = true; -- have sent whole body
	["half closed (remote)"] = true; -- have received whole body
	["reserved (local)"] = true;
	["reserved (remote)"] = true;
	["closed"] = true; -- complete
}
function stream_methods:set_state(new)
	assert(valid_states[new])
	self.state = new
end

function stream_methods:write_http2_frame(typ, flags, payload, timeout)
	return self.connection:write_http2_frame(typ, flags, self.id, payload, timeout)
end

function stream_methods:reprioritise(child, exclusive)
	assert(child)
	assert(child.id ~= 0) -- cannot reprioritise stream 0
	if self == child then
		-- http2 spec, section 5.3.1
		return nil, h2_errors.PROTOCOL_ERROR:traceback("A stream cannot depend on itself", true)
	end
	do -- Check if the child is an ancestor
		local ancestor = self.parent
		while ancestor do
			if ancestor == child then
				-- Break the loop. http spec, section 5.3.3
				local ok, err = child.parent:reprioritise(self, false)
				if not ok then return nil, err end
				break
			end
			ancestor = ancestor.parent
		end
	end
	-- Remove old parent
	if child.parent then
		child.parent.dependees[child] = nil
	end
	-- We are now the parent
	child.parent = self
	if exclusive then
		-- All the parent's deps are now the child's
		for s, v in pairs(self.dependees) do
			s.parent = child
			child.dependees[s] = v
			self.dependees[s] = nil
		end
	else
		self.dependees[child] = true
	end
	return true
end

local chunk_methods = {}
local chunk_mt = {
	__name = "http.h2_stream.chunk";
	__index = chunk_methods;
}

local function new_chunk(stream, original_length, data)
	return setmetatable({
		stream = stream;
		original_length = original_length;
		data = data;
		acked = false;
	}, chunk_mt)
end

function chunk_methods:ack(no_window_update)
	if self.acked then
		error("already acked")
	end
	self.acked = true
	local len = self.original_length
	if len > 0 and not no_window_update then
		-- ignore errors
		self.stream:write_window_update(len)
		self.stream.connection:write_window_update(len)
	end
end

-- DATA
frame_handlers[0x0] = function(stream, flags, payload)
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'DATA' frames MUST be associated with a stream")
	end
	if stream.state ~= "open" and stream.state ~= "half closed (local)" then
		return nil, h2_errors.STREAM_CLOSED:traceback("'DATA' frame not allowed in '" .. stream.state .. "' state", true)
	end

	local end_stream = band(flags, 0x1) ~= 0
	local padded = band(flags, 0x8) ~= 0

	local original_length = #payload

	if padded then
		local pad_len = sunpack("> B", payload)
		if pad_len >= #payload then -- >= will take care of the pad_len itself
			return nil, h2_errors.PROTOCOL_ERROR:traceback("length of the padding is the length of the frame payload or greater")
		elseif payload:match("[^%z]", -pad_len) then
			return nil, h2_errors.PROTOCOL_ERROR:traceback("padding not null bytes")
		end
		payload = payload:sub(2, -pad_len-1)
	end

	if end_stream then
		if stream.state == "half closed (local)" then
			stream:set_state("closed")
		else
			stream:set_state("half closed (remote)")
		end
	end

	local chunk = new_chunk(stream, original_length, payload)
	stream.chunk_fifo:push(chunk)
	if end_stream then
		stream.chunk_fifo:push(nil)
	end
	stream.chunk_cond:signal()

	return true
end

function stream_methods:write_data_frame(payload, end_stream, padded, timeout)
	if self.id == 0 then
		h2_errors.PROTOCOL_ERROR("'DATA' frames MUST be associated with a stream")
	end
	if self.state ~= "open" and self.state ~= "half closed (remote)" then
		h2_errors.STREAM_CLOSED("'DATA' frame not allowed in '" .. self.state .. "' state", true)
	end
	local pad_len, padding = "", ""
	local flags = 0
	if end_stream then
		flags = bor(flags, 0x1)
	end
	if padded then
		flags = bor(flags, 0x8)
		pad_len = spack("> B", padded)
		padding = ("\0"):rep(padded)
	end
	payload = pad_len .. payload .. padding
	-- The entire DATA frame payload is included in flow control,
	-- including Pad Length and Padding fields if present
	local new_stream_peer_flow_credits = self.peer_flow_credits - #payload
	local new_connection_peer_flow_credits = self.connection.peer_flow_credits - #payload
	if new_stream_peer_flow_credits < 0 or new_connection_peer_flow_credits < 0 then
		h2_errors.FLOW_CONTROL_ERROR("not enough flow credits")
	end
	local ok, err, errno = self:write_http2_frame(0x0, flags, payload, timeout)
	if not ok then return nil, err, errno end
	self.peer_flow_credits = new_stream_peer_flow_credits
	self.connection.peer_flow_credits = new_connection_peer_flow_credits
	self.stats_sent = self.stats_sent + #payload
	if end_stream then
		if self.state == "half closed (remote)" then
			self:set_state("closed")
		else
			self:set_state("half closed (local)")
		end
	end
	return ok
end

local function validate_headers(headers, is_request)
	do -- Validate that all colon fields are before other ones (section 8.1.2.1)
		local seen_non_colon = false
		for name in headers:each() do
			if name:sub(1,1) == ":" then
				if seen_non_colon then
					return nil, h2_errors.PROTOCOL_ERROR:traceback("All pseudo-header fields MUST appear in the header block before regular header fields")
				end
			else
				seen_non_colon = true
			end
		end
	end
	if is_request then
		--[[ All HTTP/2 requests MUST include exactly one valid value for the :method, :scheme,
		and :path pseudo-header fields, unless it is a CONNECT request (Section 8.3).
		An HTTP request that omits mandatory pseudo-header fields is malformed (Section 8.1.2.6).]]
		local methods = headers:get_as_sequence(":method")
		if methods.n ~= 1 then
			return nil, h2_errors.PROTOCOL_ERROR:traceback("requests MUST include exactly one valid value for the :method, :scheme, and :path pseudo-header fields, unless it is a CONNECT request")
		elseif methods[1] ~= "CONNECT" then
			local scheme = headers:get_as_sequence(":scheme")
			local path = headers:get_as_sequence(":path")
			if scheme.n ~= 1 or path.n ~= 1 then
				return nil, h2_errors.PROTOCOL_ERROR:traceback("requests MUST include exactly one valid value for the :method, :scheme, and :path pseudo-header fields, unless it is a CONNECT request")
			end
			if path[1] == "" and (scheme[1] == "http" or scheme[1] == "https") then
				return nil, h2_errors.PROTOCOL_ERROR:traceback("The :path pseudo-header field MUST NOT be empty for http or https URIs")
			end
		else -- is CONNECT method
			-- Section 8.3
			if headers:has(":scheme") or headers:has(":path") then
				return nil, h2_errors.PROTOCOL_ERROR:traceback("For a CONNECT request, the :scheme and :path pseudo-header fields MUST be omitted")
			end
		end
	else
		--[[ For HTTP/2 responses, a single :status pseudo-header field is
		defined that carries the HTTP status code field (RFC7231, Section 6).
		This pseudo-header field MUST be included in all responses; otherwise,
		the response is malformed (Section 8.1.2.6)]]
		if not headers:has(":status") then
			return nil, h2_errors.PROTOCOL_ERROR:traceback(":status pseudo-header field MUST be included in all responses")
		end
	end
	return true
end

local function handle_end_headers(stream)
	-- We have a full header block
	-- Have to decode now or the hpack dynamic table will go out of sync
	local payload = table.concat(stream.recv_headers_buffer, nil, 1, stream.recv_headers_buffer_items)

	local pad_len = stream.recv_headers_padding
	if pad_len > #payload then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("length of the padding is the length of the frame payload or greater")
	elseif pad_len > 0 and payload:match("[^%z]", -pad_len) then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("padding not null bytes")
	end
	payload = payload:sub(1, -pad_len-1)

	local headers, newpos = stream.connection.decoding_context:decode_headers(payload)
	if newpos ~= #payload + 1 then
		return nil, h2_errors.COMPRESSION_ERROR:traceback("incomplete header fragment")
	end

	local ok, err = validate_headers(headers, xor(stream.id % 2 == 0, stream.type == "client"))
	if not ok then return nil, err end

	stream.recv_headers_fifo:push(headers)
	stream.recv_headers_cond:signal()

	stream.recv_headers_buffer = nil
	stream.recv_headers_buffer_items = nil
	stream.recv_headers_buffer_length = nil
	stream.recv_headers_padding = nil

	return true
end

-- HEADERS
frame_handlers[0x1] = function(stream, flags, payload)
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'HEADERS' frames MUST be associated with a stream")
	end
	if stream.state ~= "idle" and stream.state ~= "open" and stream.state ~= "half closed (local)" then
		return nil, h2_errors.STREAM_CLOSED:traceback("'HEADERS' frame not allowed in '" .. stream.state .. "' state", true)
	end

	local end_stream = band(flags, 0x1) ~= 0
	local end_headers = band(flags, 0x04) ~= 0
	local padded = band(flags, 0x8) ~= 0
	local priority = band(flags, 0x20) ~= 0

	-- index where payload body starts
	local pos = 1

	if padded then
		stream.recv_headers_padding = sunpack("> B", payload, pos)
		pos = 2
	else
		stream.recv_headers_padding = 0
	end

	if priority then
		local exclusive, stream_dep, weight
		local tmp
		tmp, weight = sunpack(">I4 B", payload, pos)
		exclusive = band(tmp, 0x80000000) ~= 0
		stream_dep = band(tmp, 0x7fffffff)
		weight = weight + 1
		pos = pos + 5

		local new_parent = stream.connection.streams[stream_dep]
		if new_parent == nil then
			error("parent doesn't exist " .. stream_dep) -- FIXME
		end
		local ok, err = new_parent:reprioritise(stream, exclusive)
		if not ok then return nil, err end
		stream.weight = weight
	end

	if #payload - pos + 1 > MAX_HEADER_BUFFER_SIZE then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("headers too large")
	end

	if pos > 1 then
		payload = payload:sub(pos)
	end

	stream.recv_headers_buffer = { payload }
	stream.recv_headers_buffer_items = 1
	stream.recv_headers_buffer_length = #payload

	if end_headers then
		local ok, err = handle_end_headers(stream)
		if not ok then return nil, err end
	end

	if end_stream then
		if stream.state == "half closed (local)" then
			stream:set_state("closed")
		else
			stream:set_state("half closed (remote)")
		end
		stream.chunk_fifo:push(nil)
		stream.chunk_cond:signal()
	else
		if stream.state == "idle" then
			stream:set_state("open")
		end
	end

	return true
end

function stream_methods:write_headers_frame(payload, end_stream, end_headers, padded, exclusive, stream_dep, weight, timeout)
	assert(self.state ~= "closed" and self.state ~= "half closed (local)")
	local pad_len, pri, padding = "", "", ""
	local flags = 0
	if end_stream then
		flags = bor(flags, 0x1)
	end
	if end_headers then
		flags = bor(flags, 0x4)
	end
	if padded then
		flags = bor(flags, 0x8)
		pad_len = spack("> B", padded)
		padding = ("\0"):rep(padded)
	end
	if weight or stream_dep then
		flags = bor(flags, 0x20)
		assert(stream_dep < 0x80000000)
		local tmp = stream_dep
		if exclusive then
			tmp = bor(tmp, 0x80000000)
		end
		weight = weight and weight - 1 or 0
		pri = spack("> I4 B", tmp, weight)
	end
	payload = pad_len .. pri .. payload .. padding
	local ok, err, errno = self:write_http2_frame(0x1, flags, payload, timeout)
	if ok == nil then return nil, err, errno end
	if end_stream then
		if self.state == "reserved (local)" then
			self:set_state("closed")
		else -- self.state == "idle" or self.state == "open" then
			self:set_state("half closed (local)")
		end
	else
		if self.state == "reserved (local)" then
			self:set_state("half closed (remote)")
		elseif self.state == "idle" then
			self:set_state("open")
		end
	end
	return ok
end

-- PRIORITY
frame_handlers[0x2] = function(stream, flags, payload) -- luacheck: ignore 212
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'PRIORITY' frames MUST be associated with a stream")
	end
	if #payload ~= 5 then
		return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'PRIORITY' frames must be 5 bytes", true)
	end

	local exclusive, stream_dep, weight
	local tmp
	tmp, weight = sunpack(">I4 B", payload)
	weight = weight + 1
	exclusive = band(tmp, 0x80000000) ~= 0
	stream_dep = band(tmp, 0x7fffffff)

	local new_parent = stream.connection.streams[stream_dep]
	local ok, err = new_parent:reprioritise(stream, exclusive)
	if not ok then return nil, err end
	stream.weight = weight

	return true
end

-- RST_STREAM
frame_handlers[0x3] = function(stream, flags, payload) -- luacheck: ignore 212
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'RST_STREAM' frames MUST be associated with a stream")
	end
	if #payload ~= 4 then
		return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'RST_STREAM' frames must be 4 bytes")
	end
	if stream.state == "idle" then
		return nil, h2_errors.PROTOCOL_ERROR:traceback([['RST_STREAM' frames MUST NOT be sent for a stream in the "idle" state]])
	end

	local err_code = sunpack(">I4", payload)

	stream.rst_stream_error = (h2_errors[err_code] or h2_errors.INTERNAL_ERROR):new {
		message = string.format("'RST_STREAM' on stream #%d (code=0x%x)", stream.id, err_code);
	}

	stream:set_state("closed")
	stream.recv_headers_cond:signal()
	stream.chunk_cond:signal()

	return true
end

function stream_methods:write_rst_stream(err_code, timeout)
	if self.id == 0 then
		h2_errors.PROTOCOL_ERROR("'RST_STREAM' frames MUST be associated with a stream")
	end
	if self.state == "idle" then
		h2_errors.PROTOCOL_ERROR([['RST_STREAM' frames MUST NOT be sent for a stream in the "idle" state]], true)
	end
	local flags = 0
	local payload = spack(">I4", err_code)
	local ok, err, errno = self:write_http2_frame(0x3, flags, payload, timeout)
	if not ok then return nil, err, errno end
	self:set_state("closed")
	return ok
end

-- SETTING
frame_handlers[0x4] = function(stream, flags, payload)
	if stream.id ~= 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("stream identifier for a 'SETTINGS' frame MUST be zero")
	end

	local ack = band(flags, 0x1) ~= 0
	if ack then -- server is ACK-ing our settings
		if #payload ~= 0 then
			return nil, h2_errors.FRAME_SIZE_ERROR:traceback("Receipt of a 'SETTINGS' frame with the ACK flag set and a length field value other than 0")
		end
		stream.connection:ack_settings()
		return true
	else -- settings from server
		if #payload % 6 ~= 0 then
			return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'SETTINGS' frame with a length other than a multiple of 6 octets")
		end
		local peer_settings = {}
		for i=1, #payload, 6 do
			local id, val = sunpack(">I2 I4", payload, i)
			if id == 0x1 then
				stream.connection.encoding_context:set_max_dynamic_table_size(val)
				-- Add a 'max size' element to the next outgoing header
				stream.connection.encoding_context:encode_max_size(val)
			elseif id == 0x2 then
				-- Convert to boolean
				if val == 0 then
					val = false
				elseif val == 1 then
					val = true
				else
					return nil, h2_errors.PROTOCOL_ERROR:traceback()
				end
				if val and stream.type == "client" then
					-- Clients MUST reject any attempt to change the SETTINGS_ENABLE_PUSH
					-- setting to a value other than 0 by treating the message as a connection
					-- error of type PROTOCOL_ERROR.
					return nil, h2_errors.PROTOCOL_ERROR:traceback("SETTINGS_ENABLE_PUSH not allowed for clients")
				end
			elseif id == 0x4 then
				if val >= 2^31 then
					return nil, h2_errors.FLOW_CONTROL_ERROR:traceback("SETTINGS_INITIAL_WINDOW_SIZE must be less than 2^31")
				end
			elseif id == 0x5 then
				if val < 16384 then
					return nil, h2_errors.PROTOCOL_ERROR:traceback("SETTINGS_MAX_FRAME_SIZE must be greater than or equal to 16384")
				elseif val >= 2^24 then
					return nil, h2_errors.PROTOCOL_ERROR:traceback("SETTINGS_MAX_FRAME_SIZE must be less than 2^24")
				end
			end
			peer_settings[id] = val
		end
		stream.connection:set_peer_settings(peer_settings)
		-- Ack server's settings
		return stream:write_settings_frame(true)
	end
end

local function pack_settings_payload(settings)
	local i = 0
	local a = {}
	local function append(k, v)
		a[i*2+1] = k
		a[i*2+2] = v
		i = i + 1
	end
	local HEADER_TABLE_SIZE = settings[0x1]
	if HEADER_TABLE_SIZE ~= nil then
		append(0x1, HEADER_TABLE_SIZE)
	end
	local ENABLE_PUSH = settings[0x2]
	if ENABLE_PUSH ~= nil then
		if type(ENABLE_PUSH) == "boolean" then
			ENABLE_PUSH = ENABLE_PUSH and 1 or 0
		end
		append(0x2, ENABLE_PUSH)
	end
	local MAX_CONCURRENT_STREAMS = settings[0x3]
	if MAX_CONCURRENT_STREAMS ~= nil then
		append(0x3, MAX_CONCURRENT_STREAMS)
	end
	local INITIAL_WINDOW_SIZE = settings[0x4]
	if INITIAL_WINDOW_SIZE ~= nil then
		if INITIAL_WINDOW_SIZE >= 2^31 then
			h2_errors.FLOW_CONTROL_ERROR("SETTINGS_INITIAL_WINDOW_SIZE must be less than 2^31")
		end
		append(0x4, INITIAL_WINDOW_SIZE)
	end
	local MAX_FRAME_SIZE = settings[0x5]
	if MAX_FRAME_SIZE ~= nil then
		if MAX_FRAME_SIZE < 16384 then
			h2_errors.PROTOCOL_ERROR("SETTINGS_MAX_FRAME_SIZE must be greater than or equal to 16384")
		elseif MAX_FRAME_SIZE >= 2^24 then
			h2_errors.PROTOCOL_ERROR("SETTINGS_MAX_FRAME_SIZE must be less than 2^24")
		end
		append(0x5, MAX_FRAME_SIZE)
	end
	local MAX_HEADER_LIST_SIZE = settings[0x6]
	if MAX_HEADER_LIST_SIZE ~= nil then
		append(0x6, MAX_HEADER_LIST_SIZE)
	end
	return spack(">" .. ("I2 I4"):rep(i), unpack(a, 1, i*2))
end

function stream_methods:write_settings_frame(ACK, settings, timeout)
	if self.id ~= 0 then
		h2_errors.PROTOCOL_ERROR("'SETTINGS' frames must be on stream id 0")
	end
	local flags, payload
	if ACK then
		if settings ~= nil then
			h2_errors.PROTOCOL_ERROR("'SETTINGS' ACK cannot have new settings")
		end
		flags = 0x1
		payload = ""
	else
		flags = 0
		payload = pack_settings_payload(settings)
	end
	return self:write_http2_frame(0x4, flags, payload, timeout)
end

-- PUSH_PROMISE
frame_handlers[0x5] = function(stream, flags, payload)
	if not stream.connection.acked_settings[0x2] then
		-- An endpoint that has both set this parameter to 0 and had it acknowledged MUST
		-- treat the receipt of a PUSH_PROMISE frame as a connection error of type PROTOCOL_ERROR.
		return nil, h2_errors.PROTOCOL_ERROR:traceback("SETTINGS_ENABLE_PUSH is 0")
	elseif stream.type == "server" then
		-- A client cannot push. Thus, servers MUST treat the receipt of a PUSH_PROMISE
		-- frame as a connection error of type PROTOCOL_ERROR.
		return nil, h2_errors.PROTOCOL_ERROR:traceback("A client cannot push")
	end
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'PUSH_PROMISE' frames MUST be associated with a stream")
	end

	local end_headers = band(flags, 0x04) ~= 0
	local padded = band(flags, 0x8) ~= 0

	if padded then
		local pad_len = sunpack("> B", payload)
		if pad_len >= #payload then -- >= will take care of the pad_len itself
			return nil, h2_errors.PROTOCOL_ERROR:traceback("length of the padding is the length of the frame payload or greater")
		elseif payload:match("[^%z]", -pad_len) then
			return nil, h2_errors.PROTOCOL_ERROR:traceback("padding not null bytes")
		end
		payload = payload:sub(2, -pad_len-1)
	end

	local tmp = sunpack(">I4", payload)
	local exclusive = band(tmp, 0x80000000) ~= 0
	local promised_stream = band(tmp, 0x7fffffff)
	local header_fragment = payload:sub(5)

	error(string.format("NYI: PUSH_PROMISE (id=%d, exclusive?=%s, promised=%d, #fragment=%d)",
		stream.id, end_headers, tostring(exclusive), promised_stream, header_fragment))
end

-- PING
frame_handlers[0x6] = function(stream, flags, payload)
	if stream.id ~= 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'PING' must be on stream id 0")
	end
	if #payload ~= 8 then
		return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'PING' frames must be 8 bytes")
	end

	local ack = band(flags, 0x1) ~= 0

	if ack then
		local cond = stream.connection.pongs[payload]
		if cond then
			cond:signal()
			stream.connection.pongs[payload] = nil
		end
		return true
	else
		return stream:write_ping_frame(true, payload)
	end
end

function stream_methods:write_ping_frame(ACK, payload, timeout)
	if self.id ~= 0 then
		h2_errors.PROTOCOL_ERROR("'PING' frames must be on stream id 0")
	end
	if #payload ~= 8 then
		h2_errors.FRAME_SIZE_ERROR("'PING' frames must have 8 byte payload")
	end
	local flags = ACK and 0x1 or 0
	return self:write_http2_frame(0x6, flags, payload, timeout)
end

-- GOAWAY
frame_handlers[0x7] = function(stream, flags, payload) -- luacheck: ignore 212
	if stream.id ~= 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'GOAWAY' frames must be on stream id 0")
	end
	if #payload < 8 then
		return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'GOAWAY' frames must be at least 8 bytes")
	end

	local last_streamid = sunpack(">I4 I4", payload)

	if stream.connection.recv_goaway_lowest == nil or last_streamid < stream.connection.recv_goaway_lowest then
		stream.connection.recv_goaway_lowest = last_streamid
		stream.connection.recv_goaway:signal()
	end

	return true
end

function stream_methods:write_goaway_frame(last_streamid, err_code, debug_msg, timeout)
	if self.id ~= 0 then
		h2_errors.PROTOCOL_ERROR("'GOAWAY' frames MUST be on stream 0")
	end
	assert(last_streamid)
	local flags = 0
	local payload = spack(">I4 I4", last_streamid, err_code)
	if debug_msg then
		payload = payload .. debug_msg
	end
	return self:write_http2_frame(0x7, flags, payload, timeout)
end

-- WINDOW_UPDATE
frame_handlers[0x8] = function(stream, flags, payload) -- luacheck: ignore 212
	if #payload ~= 4 then
		return nil, h2_errors.FRAME_SIZE_ERROR:traceback("'WINDOW_UPDATE' frames must be 4 bytes")
	end
	if stream.id ~= 0 and stream.state == "idle" then
		return nil, h2_errors.PROTOCOL_ERROR([['WINDOW_UPDATE' frames not allowed in "idle" state]], true)
	end

	local tmp = sunpack(">I4", payload)
	assert(band(tmp, 0x80000000) == 0, "'WINDOW_UPDATE' reserved bit set")
	local increment = band(tmp, 0x7fffffff)
	if increment == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'WINDOW_UPDATE' MUST not have an increment of 0", stream.id ~= 0)
	end

	local ob
	if stream.id == 0 then -- for connection
		ob = stream.connection
	else
		ob = stream
	end
	local newval = ob.peer_flow_credits + increment
	if newval > 2^31-1 then
		return nil, h2_errors.FLOW_CONTROL_ERROR:traceback("A sender MUST NOT allow a flow-control window to exceed 2^31-1 octets", stream.id ~= 0)
	end
	ob.peer_flow_credits = newval
	ob.peer_flow_credits_increase:signal()

	return true
end

function stream_methods:write_window_update_frame(inc, timeout)
	local flags = 0
	if self.id ~= 0 and self.state == "idle" then
		h2_errors.PROTOCOL_ERROR([['WINDOW_UPDATE' frames not allowed in "idle" state]], true)
	end
	if inc >= 0x80000000 or inc <= 0 then
		h2_errors.PROTOCOL_ERROR("invalid window update increment", true)
	end
	local payload = spack(">I4", inc)
	return self:write_http2_frame(0x8, flags, payload, timeout)
end

function stream_methods:write_window_update(inc)
	while inc >= 0x80000000 do
		local ok, err = self:write_window_update_frame(0x7fffffff)
		if not ok then return nil, err end
		inc = inc - 0x7fffffff
	end
	return self:write_window_update_frame(inc)
end

-- CONTINUATION
frame_handlers[0x9] = function(stream, flags, payload)
	if stream.id == 0 then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'CONTINUATION' frames MUST be associated with a stream")
	end
	if stream.recv_headers_buffer_length == nil then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("'CONTINUATION' frames MUST be preceded by a 'HEADERS', 'PUSH_PROMISE' or 'CONTINUATION' frame without the 'END_HEADERS' flag set")
	end

	local end_headers = band(flags, 0x04) ~= 0
	local header_fragment = payload

	local l = stream.recv_headers_buffer_length + #header_fragment
	if l > MAX_HEADER_BUFFER_SIZE then
		return nil, h2_errors.PROTOCOL_ERROR:traceback("headers too large")
	end
	local i = stream.recv_headers_buffer_items + 1
	stream.recv_headers_buffer[i] = header_fragment
	stream.recv_headers_buffer_items = i
	stream.recv_headers_buffer_length = l

	if end_headers then
		return handle_end_headers(stream)
	else
		return true
	end
end

function stream_methods:write_continuation_frame(payload, end_headers, timeout)
	assert(self.state == "open" or self.state == "half closed (remote)")
	local flags = 0
	if end_headers then
		flags = bor(flags, 0x4)
	end
	return self:write_http2_frame(0x9, flags, payload, timeout)
end

-------------------------------------------

function stream_methods:shutdown()
	if self.state ~= "idle" and self.state ~= "closed" and self.id ~= 0 then
		local ok, err = self:write_rst_stream(0)
		if not ok and err ~= ce.EPIPE then
			error(err)
		end
	end
	local len = 0
	while self.chunk_fifo:length() > 0 do
		local chunk = self.chunk_fifo:pop()
		if chunk ~= nil then
			chunk:ack(true)
			len = len + #chunk.data
		end
	end
	if len > 0 then
		self.connection:write_window_update(len)
	end
end

-- this function *should never throw*
function stream_methods:get_headers(timeout)
	local deadline = timeout and (monotime()+timeout)
	while self.recv_headers_fifo:length() < 1 do
		if self.state == "closed" then
			return nil, self.rst_stream_error
		end
		local which = cqueues.poll(self.connection, self.recv_headers_cond, timeout)
		if which == self.connection then
			local ok, err = self.connection:step(0)
			if not ok then
				return nil, err
			end
		elseif which == timeout then
			return nil, ce.ETIMEDOUT
		end
		timeout = deadline and (deadline-monotime())
	end
	local headers = self.recv_headers_fifo:pop()
	return headers
end

function stream_methods:get_next_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	while self.chunk_fifo:length() == 0 do
		if self.state == "closed" or self.state == "half closed (remote)" then
			if self.rst_stream_error then
				self.rst_stream_error()
			end
			return nil
		end
		local which = cqueues.poll(self.connection, self.chunk_cond, timeout)
		if which == self.connection then
			local ok, err = self.connection:step(0)
			if not ok then
				return nil, err
			end
		elseif which == timeout then
			return nil, ce.ETIMEDOUT
		end
		timeout = deadline and (deadline-monotime())
	end
	local chunk = self.chunk_fifo:pop()
	if chunk == nil then
		return nil, ce.EPIPE
	else
		local data = chunk.data
		chunk:ack(false)
		return data
	end
end

function stream_methods:write_headers(headers, end_stream, timeout)
	local deadline = timeout and (monotime()+timeout)
	assert(headers, "missing argument: headers")
	assert(validate_headers(headers, xor(self.id % 2 == 1, self.type == "client")))
	assert(type(end_stream) == "boolean", "'end_stream' MUST be a boolean")
	local encoding_context = self.connection.encoding_context
	encoding_context:encode_headers(headers)
	local payload = encoding_context:render_data()
	encoding_context:clear_data()

	local SETTINGS_MAX_FRAME_SIZE = self.connection.peer_settings[0x5]
	local padded, exclusive, stream_dep, weight = nil, nil, nil, nil
	if #payload <= SETTINGS_MAX_FRAME_SIZE then
		assert(self:write_headers_frame(payload, end_stream, true, padded, exclusive, stream_dep, weight, timeout))
	else
		do
			local partial = payload:sub(1, SETTINGS_MAX_FRAME_SIZE)
			assert(self:write_headers_frame(partial, end_stream, false, padded, exclusive, stream_dep, weight, timeout))
		end
		local sent = SETTINGS_MAX_FRAME_SIZE
		local max = #payload-SETTINGS_MAX_FRAME_SIZE
		while sent < max do
			local partial = payload:sub(sent+1, sent+SETTINGS_MAX_FRAME_SIZE)
			assert(self:write_continuation_frame(partial, false, deadline and (deadline-monotime())))
			sent = sent + SETTINGS_MAX_FRAME_SIZE
		end
		do
			local partial = payload:sub(sent+1)
			assert(self:write_continuation_frame(partial, true, deadline and (deadline-monotime())))
		end
	end

	return true
end

function stream_methods:write_chunk(payload, end_stream, timeout)
	local deadline = timeout and (monotime()+timeout)
	local sent = 0
	while true do
		while self.peer_flow_credits == 0 do
			local which = cqueues.poll(self.connection, self.peer_flow_credits_increase, timeout)
			if which == self.connection then
				assert(self.connection:step(0))
			elseif which == timeout then
				return nil, ce.ETIMEDOUT
			end
			timeout = deadline and (deadline-monotime())
		end
		while self.connection.peer_flow_credits == 0 do
			local which = cqueues.poll(self.connection, self.connection.peer_flow_credits_increase, timeout)
			if which == self.connection then
				assert(self.connection:step(0))
			elseif which == timeout then
				return nil, ce.ETIMEDOUT
			end
			timeout = deadline and (deadline-monotime())
		end
		local SETTINGS_MAX_FRAME_SIZE = self.connection.peer_settings[0x5]
		local max_available = math.min(self.peer_flow_credits, self.connection.peer_flow_credits, SETTINGS_MAX_FRAME_SIZE)
		if max_available < (#payload - sent) then
			if max_available > 0 then
				-- send partial payload
				local ok, err = self:write_data_frame(payload:sub(sent+1, sent+max_available), false, timeout)
				if not ok then
					if err == ce.EPIPE or err == ce.ETIMEDOUT then
						return nil, err
					end
					error(err)
				end
				sent = sent + max_available
			end
		else
			break
		end
		timeout = deadline and (deadline-monotime())
	end
	local ok, err = self:write_data_frame(payload:sub(sent+1), end_stream, timeout)
	if not ok then
		if err == ce.EPIPE or err == ce.ETIMEDOUT then
			return nil, err
		end
		error(err)
	end
	return true
end

return {
	new = new_stream;
	methods = stream_methods;
	mt = stream_mt;

	frame_handlers = frame_handlers;
	pack_settings_payload = pack_settings_payload;
}
