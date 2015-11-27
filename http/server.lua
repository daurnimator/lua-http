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
local function wrap_socket(socket, tbl, ctx, timeout)
	local deadline = timeout and (monotime()+timeout)
	socket:setmode("b", "b")
	socket:onerror(onerror)
	local use_tls = tbl.tls
	if use_tls == nil then
		local err, errno
		use_tls, err, errno = is_tls_client_hello(socket, deadline and (deadline-monotime()))
		if use_tls == nil then
			return nil, err, errno
		end
	end
	local is_h2 -- tri-state
	if use_tls then
		local ok, err, errno = socket:starttls(ctx, deadline and (deadline-monotime()))
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

-- Starts listening on the given socket
local function listen(tbl, on_stream, cq)
	local running = assert(cqueues.running(), "must be running inside of a cqueue")
	cq = cq or running
	local tls = tbl.tls
	local host = assert(tbl.host, "need host")
	local port = tbl.port or tls and "443" or "80"
	local max_concurrent = tbl.max_concurrent or math.huge
	assert(max_concurrent > 0)
	-- timeout waiting for client to send first bytes and/or complete TLS handshake
	local wrap_timeout = tbl.client_timeout or 10
	local ctx
	if type(tls) == "userdata" then
		ctx = tls
	elseif tls ~= false then
		ctx = new_ctx(host)
	end
	local s = assert(cs.listen{
		host = host;
		port = port;
		v6only = tbl.v6only;
		reuseaddr = tbl.reuseaddr;
		reuseport = tbl.reuseport;
	})
	s:listen() -- Actually wait for and *do* the binding
	-- Return errors rather than throwing
	s:onerror(function(s, op, why, lvl) -- luacheck: ignore 431 212
		return why
	end)

	local n = 0
	local done = cc.new()
	while true do
		if n >= max_concurrent then
			done:wait()
		end
		-- Yield this thread until a client arrives
		local socket, accept_err = s:accept{nodelay = true;}
		if socket == nil then
			if accept_err == ce.EMFILE then
				-- Wait for another request to finish
				if not done:wait(0.1) then
					-- If we're stuck waiting for more than 100ms, run a garbage collection sweep
					-- This can prevent a hang
					collectgarbage()
				end
			else
				error(ce.strerror(accept_err))
			end
		else
			n = n + 1
			cq:wrap(function()
				local ok, err
				local conn, is_h2, errno = wrap_socket(socket, tbl, ctx, wrap_timeout)
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
				n = n - 1
				done:signal(1)
				if not ok
					and err ~= ce.EPIPE -- client closed connection
					and err ~= ce.ETIMEDOUT -- an operation timed out
				then
					error(err)
				end
			end)
		end
	end
end

return {
	listen = listen;
}
