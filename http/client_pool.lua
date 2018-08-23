local cs = require "cqueues.socket"

local function reuse_connection(candidate, connect_options)
	-- Assume family/host/port/path already checked

	if candidate.socket == nil then
		return false
	end

	if connect_options.v6only then
		-- TODO
		return false
	end

	local bind = connect_options.bind
	if bind then
		-- TODO: Use :localname()
		return false
	end

	local version = connect_options.version
	if version and version ~= candidate.version then
		return false
	end

	if candidate.version < 2 then
		-- Check if connection already in use (avoid pipelining)
		if candidate.req_locked then
			return false
		end
	elseif candidate.version == 2 then
		-- Check if http2 connection is nearing end of stream ids
		local highest_stream_id = math.max(candidate.highest_odd_stream, candidate.highest_even_stream)
		-- The stream id is a unsigned 31bit integer. we don't reuse if it's past half way
		if highest_stream_id > 0x3fffffff then
			return false
		end

		local h2_settings = connect_options.h2_settings
		if h2_settings then
			-- TODO: check (and possibly change on connection?)
			return false
		end
	end

	-- Do TLS check last, as it is the most expensive
	if connect_options.tls then
		-- TODO: compare TLS parameters
		return false
	end

	-- Check to see if connection has been closed
	local ok, err = candidate.socket:fill(1, 0)
	if not ok and err == nil then
		-- has been closed
		return false
	end

	return true
end

local pool_methods = {}
local pool_mt = {
	__name = "http.client.pool";
	__index = pool_methods;
}

local function new_pool()
	return setmetatable({}, pool_mt)
end

local function ipv4_pool_key(addr, port)
	return string.format("%d:%s:%s", cs.AF_INET, addr, port)
end

local function ipv6_pool_key(addr, port)
	return string.format("%d:[%s]:%s", cs.AF_INET6, addr, port)
end

local function unix_pool_key(path)
	return string.format("%d:%s", cs.AF_UNIX, path)
end

local function connection_pool_key(connection)
	-- XXX: if using a proxy this may not be correct
	local family, a, b = connection:peername()
	if family == cs.AF_INET then
		return ipv4_pool_key(a, b)
	elseif family == cs.AF_INET6 then
		return ipv6_pool_key(a, b)
	elseif family == cs.AF_UNIX then
		return unix_pool_key(a)
	end
end

function pool_methods:add(connection)
	local key = connection_pool_key(connection)
	if not key then
		return false
	end
	local dst_pool = self[key]
	if dst_pool == nil then
		dst_pool = {}
		self[key] = dst_pool
	end
	dst_pool[connection] = true
	return true
end

function pool_methods:remove(connection)
	local key = connection_pool_key(connection)
	if not key then
		return true
	end
	local dst_pool = self[key]
	if dst_pool == nil then
		return true
	end
	dst_pool[connection] = nil
	if next(dst_pool) == nil then
		self[key] = nil
	end
	return true
end

local function find_connection(dst_pool, connect_options)
	for connection in pairs(dst_pool) do
		if reuse_connection(connection, connect_options) then
			return connection
		end
	end
	return nil
end

return {
	ipv4_pool_key = ipv4_pool_key;
	ipv6_pool_key = ipv6_pool_key;
	unix_pool_key = unix_pool_key;

	new = new_pool;
	find_connection = find_connection;
}
