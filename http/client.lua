local cs = require "cqueues.socket"
local ce = require "cqueues.errno"
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
	if why == ce.ETIMEDOUT then
		return why
	end
	return string.format("%s: %s", op, ce.strerror(why)), why
end

local function negotiate(s, options, timeout)
	s:onerror(onerror)
	local tls = options.tls
	local version = options.version
	if tls then
		if tls == true then
			if version == nil then
				tls = default_ctx
			elseif version == 1 then
				tls = default_h1_ctx
			elseif version == 1.1 then
				tls = default_h11_ctx
			elseif version == 2 then
				tls = default_h2_ctx
			else
				error("Unknown HTTP version: " .. tostring(version))
			end
		end
		local ok, err, errno = s:starttls(tls, timeout)
		if not ok then
			return nil, err, errno
		end
	end
	if version == nil then
		if tls then
			local ssl = s:checktls()
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
	-- TODO: https://github.com/wahern/cqueues/issues/124
	local s, errno = cs.connect {
		family = options.family;
		host = options.host;
		port = options.port;
		path = options.path;
		sendname = options.sendname;
		v6only = options.v6only;
		nodelay = true;
	}
	if s == nil then
		return nil, ce.strerror(errno), errno
	end
	return negotiate(s, options, timeout)
end

return {
	negotiate = negotiate;
	connect = connect;
}
