local ca = require "cqueues.auxlib"
local ce = require "cqueues.errno"
local cs = require "cqueues.socket"
local http_tls = require "http.tls"
local new_h1_connection = require "http.h1_connection".new
local new_h2_connection = require "http.h2_connection".new
local openssl_ctx = require "openssl.ssl.context"

-- Create a shared 'default' TLS contexts
local default_ctx = http_tls.new_client_context()
local default_h1_ctx
local default_h11_ctx
local default_h2_ctx = http_tls.new_client_context()
if http_tls.has_alpn then
	default_ctx:setAlpnProtos({"h2", "http/1.1"})

	default_h1_ctx = http_tls.new_client_context()

	default_h11_ctx = http_tls.new_client_context()
	default_h11_ctx:setAlpnProtos({"http/1.1"})

	default_h2_ctx:setAlpnProtos({"h2"})
else
	default_h1_ctx = default_ctx
	default_h11_ctx = default_ctx
end
default_h2_ctx:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)

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
	return err, why
end

local function negotiate(s, options, timeout)
	s:onerror(onerror)
	local tls = options.tls
	local version = options.version
	if tls then
		local ctx = options.ctx
		if ctx == nil then
			if version == nil then
				ctx = default_ctx
			elseif version == 1 then
				ctx = default_h1_ctx
			elseif version == 1.1 then
				ctx = default_h11_ctx
			elseif version == 2 then
				ctx = default_h2_ctx
			else
				error("Unknown HTTP version: " .. tostring(version))
			end
		end
		local ok, err, errno = s:starttls(ctx, timeout)
		if not ok then
			return nil, err, errno
		end
	end
	if version == nil then
		local ssl = s:checktls()
		if ssl then
			if http_tls.has_alpn and ssl:getAlpnSelected() == "h2" then
				version = 2
			else
				version = 1.1
			end
		else
			-- TODO: attempt upgrading http1 to http2
			version = 1.1
		end
	end
	if version < 2 then
		return new_h1_connection(s, "client", version)
	elseif version == 2 then
		return new_h2_connection(s, "client", options.h2_settings)
	else
		error("Unknown HTTP version: " .. tostring(version))
	end
end

local function connect(options, timeout)
	local s, err, errno = ca.fileresult(cs.connect {
		family = options.family;
		host = options.host;
		port = options.port;
		path = options.path;
		sendname = options.sendname;
		v6only = options.v6only;
		nodelay = true;
	})
	if s == nil then
		return nil, err, errno
	end
	return negotiate(s, options, timeout)
end

return {
	negotiate = negotiate;
	connect = connect;
}
