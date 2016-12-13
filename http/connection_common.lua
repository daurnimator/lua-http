local ca = require "cqueues.auxlib"
local ce = require "cqueues.errno"

local connection_methods = {}
local connection_mt = {
	__name = "http.connection_common";
	__index = connection_methods;
}

local function onerror(socket, op, why, lvl) -- luacheck: ignore 212
	local err = string.format("%s: %s", op, ce.strerror(why))
	if op == "starttls" then
		local ssl = socket:checktls()
		if ssl and ssl.getVerifyResult then
			local code, msg = ssl:getVerifyResult()
			if code ~= 0 then
				err = err .. ":" .. msg
			end
		end
	end
	if why == ce.ETIMEDOUT then
		if op == "fill" or op == "read" then
			socket:clearerr("r")
		elseif op == "flush" then
			socket:clearerr("w")
		end
	end
	return err, why
end

-- assumes ownership of the socket
local function new_connection(socket, conn_type)
	assert(socket, "must provide a socket")
	if conn_type ~= "client" and conn_type ~= "server" then
		error('invalid connection type. must be "client" or "server"')
	end
	local self = setmetatable({
		socket = socket;
		type = conn_type;
		version = nil;
		-- A function that will be called if the connection becomes idle
		onidle_ = nil;
	}, connection_mt)
	socket:setmode("b", "bf")
	socket:onerror(onerror)
	return self
end

function connection_methods:onidle_() -- luacheck: ignore 212
end

function connection_methods:onidle(...)
	local old_handler = self.onidle_
	if select("#", ...) > 0 then
		self.onidle_ = ...
	end
	return old_handler
end

function connection_methods:connect(timeout)
	if self.socket == nil then
		return nil
	end
	local ok, err, errno = self.socket:connect(timeout)
	if not ok then
		return nil, err, errno
	end
	return true
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
	return ca.fileresult(self.socket:localname())
end

function connection_methods:peername()
	if self.socket == nil then
		return nil
	end
	return ca.fileresult(self.socket:peername())
end

return {
	onerror = onerror;
	new = new_connection;
	methods = connection_methods;
	mt = connection_mt;
}
