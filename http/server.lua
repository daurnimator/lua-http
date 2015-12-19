local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cs = require "cqueues.socket"
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local h1_connection = require "http.h1_connection"
local h2_connection = require "http.h2_connection"
local new_server_context = require "http.tls".new_server_context
local pkey = require "openssl.pkey"
local x509 = require "openssl.x509"
local name = require "openssl.x509.name"
local altname = require "openssl.x509.altname"

local function onerror(socket, op, why, lvl) -- luacheck: ignore 212
	if why == ce.EPIPE or why == ce.ETIMEDOUT then
		return why
	end
	return string.format("%s: %s", op, ce.strerror(why)), why
end

-- Sense for TLS or SSL client hello
-- returns `true`, `false` or `nil, err`
local function is_tls_client_hello(socket, timeout)
	-- reading for 6 bytes should be safe, as no HTTP version
	-- has a valid client request shorter than 6 bytes
	local first_bytes, err, errno = socket:xread(6, timeout)
	if first_bytes == nil then
		return nil, err or ce.EPIPE, errno
	end
	local use_tls = not not (
		first_bytes:match("^\22\3...\1") or -- TLS
		first_bytes:match("^[\128-\255][\9-\255]\1") -- SSLv2
	)
	local ok
	ok, errno = socket:unget(first_bytes)
	if not ok then
		return nil, onerror(socket, "unget", errno, 2)
	end
	return use_tls
end

-- Wrap a bare cqueues socket in a http connection of a suitable version
-- Starts TLS if necessary
-- this function *should never throw*
local function wrap_socket(self, socket, deadline)
	socket:setmode("b", "b")
	socket:onerror(onerror)
	local use_tls = self.tls
	if use_tls == nil then
		local err, errno
		use_tls, err, errno = is_tls_client_hello(socket, deadline and (deadline-monotime()))
		if use_tls == nil then
			return nil, err, errno
		end
	end
	local is_h2 -- tri-state
	if use_tls then
		local ok, err, errno = socket:starttls(self.ctx, deadline and (deadline-monotime()))
		if not ok then
			return nil, err, errno
		end
		local ssl = socket:checktls()
		if ssl and ssl.getAlpnSelected then
			local proto = ssl:getAlpnSelected()
			if proto == "h2" then
				is_h2 = true
			elseif proto == nil then
				is_h2 = false
			else
				return nil, "unexpected ALPN protocol: " .. proto
			end
		end
	end
	-- Still not sure if incoming connection is a http1 or http2 connection
	-- Need to sniff for the h2 connection preface to find out for sure
	if is_h2 == nil then
		local err, errno
		is_h2, err, errno = h2_connection.socket_has_preface(socket, true, deadline and (deadline-monotime()))
		if is_h2 == nil then
			return nil, err, errno
		end
	end
	local conn, err, errno
	if is_h2 then
		conn, err, errno = h2_connection.new(socket, "server", nil, deadline and (deadline-monotime()))
	else
		conn, err, errno = h1_connection.new(socket, "server", 1.1)
	end
	if not conn then
		return nil, err, errno
	end
	return conn, is_h2
end

-- this function *should never throw*
local function handle_client(conn, on_stream)
	while true do
		local stream, err, errno = conn:get_next_incoming_stream()
		if stream == nil then
			if (err == ce.EPIPE or errno == ce.ECONNRESET or errno == ce.ENOTCONN) and conn.socket:pending() == 0 then
				break
			else
				return nil, err, errno
			end
		end
		on_stream(stream)
	end
	-- wait for streams to complete?
	return true
end

-- Pick h2 if available
local function pick_h2(ssl, protos) -- luacheck: ignore 212
	for _, proto in ipairs(protos) do
		if proto == "h2" then return "h2" end
	end
	return nil
end

-- create a new self signed cert
local function new_ctx(host)
	local ctx = new_server_context()
	if ctx.setAlpnSelect then
		ctx:setAlpnSelect(pick_h2)
	end
	local crt = x509.new()
	-- serial needs to be unique or browsers will show uninformative error messages
	crt:setSerial(os.time())
	-- use the host we're listening on as canonical name
	local dn = name.new()
	dn:add("CN", host)
	crt:setSubject(dn)
	local alt = altname.new()
	alt:add("DNS", host)
	crt:setSubjectAlt(alt)
	-- lasts for 10 years
	crt:setLifetime(os.time(), os.time()+86400*3650)
	-- can't be used as a CA
	crt:setBasicConstraints{CA=false}
	crt:setBasicConstraintsCritical(true)
	-- generate a new private/public key pair
	local key = pkey.new()
	crt:setPublicKey(key)
	crt:sign(key)
	assert(ctx:setPrivateKey(key))
	assert(ctx:setCertificate(crt))
	return ctx
end

local server_methods = {
	max_concurrent = math.huge;
	client_timeout = 10;
}
local server_mt = {
	__name = "http.server";
	__index = server_methods;
}

--[[ Starts listening on the given socket

Takes a table of options:
  - `.host`: address to bind to (required)
  - `.port`: port to bind to (optional if tls isn't `nil`, in which case defaults to 80 for `.tls == false` or 443 if `.tls == true`)
  - `.v6only`: allow ipv6 only (no ipv4-mapped-ipv6)
  - `.reuseaddr`: turn on SO_REUSEADDR flag?
  - `.reuseport`: turn on SO_REUSEPORT flag?
  - `.tls`: `nil`: allow both tls and non-tls connections
  -         `true`: allows tls connections only
  -         `false`: allows non-tls connections only
  - `.ctx`: an `openssl.ssl.context` object to use for tls connections
  - `       `nil`: a self-signed context will be generated
  - `.max_concurrent`: Maximum number of connections to allow live at a time (default: infinity)
  - `.client_timeout`: Timeout (in seconds) to wait for client to send first bytes and/or complete TLS handshake (default: 10)
]]
local function listen(tbl)
	local tls = tbl.tls
	local host = assert(tbl.host, "need host")
	local port = tbl.port
	if port == nil then
		if tls == true then
			port = "443"
		elseif tls == false then
			port = "80"
		else
			error("need port")
		end
	end
	local ctx = tbl.ctx
	if ctx == nil and tls ~= false then
		ctx = new_ctx(host)
	end
	local s = assert(cs.listen{
		host = host;
		port = port;
		v6only = tbl.v6only;
		reuseaddr = tbl.reuseaddr;
		reuseport = tbl.reuseport;
	})
	-- Return errors rather than throwing
	s:onerror(function(s, op, why, lvl) -- luacheck: ignore 431 212
		return why
	end)

	return setmetatable({
		socket = s;
		tls = tls;
		ctx = ctx;
		max_concurrent = tbl.max_concurrent;
		n_connections = 0;
		connection_done = cc.new(); -- signalled when connection has been closed
		client_timeout = tbl.client_timeout;
	}, server_mt)
end

-- Actually wait for and *do* the binding
-- Don't *need* to call this, as if not it will be done lazily
function server_methods:listen(timeout)
	return self.socket:listen(timeout)
end

function server_methods:localname()
	self.socket:localname()
end

function server_methods:shutdown()
	self.socket:shutdown()
end

function server_methods:close()
	self:shutdown()
	cqueues.poll()
	cqueues.poll()
	self.socket:close()
end

-- accepts a new client and returns it as an http connection object
function server_methods:run(on_stream, cq)
	cq = cq or cqueues.running()
	while true do
		if self.n_connections >= self.max_concurrent then
			self.connection_done:wait()
		end
		-- Yield this thread until a client arrives
		local socket, accept_err = self.socket:accept{nodelay = true;}
		if socket == nil then
			if accept_err == ce.EINVAL then
				-- has been shutdown
				break
			elseif accept_err == ce.EMFILE then
				-- Wait for another request to finish
				if not self.connection_done:wait(0.1) then
					-- If we're stuck waiting for more than 100ms, run a garbage collection sweep
					-- This can prevent a hang
					collectgarbage()
				end
			else
				error(ce.strerror(accept_err))
			end
		else
			self.n_connections = self.n_connections + 1
			cq:wrap(function()
				local ok, err
				local conn, is_h2, errno = wrap_socket(self, socket)
				if not conn then
					err = is_h2
					socket:close()
					if errno == ce.ECONNRESET then
						ok = true
					end
				else
					ok, err = handle_client(conn, on_stream)
					conn:close()
				end
				self.n_connections = self.n_connections - 1
				self.connection_done:signal(1)
				if not ok
					and err ~= ce.EPIPE -- client closed connection
					and err ~= ce.ETIMEDOUT -- an operation timed out
				then
					error(err)
				end
			end)
		end
	end
	return true
end

return {
	listen = listen;
}
