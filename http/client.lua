local ca = require "cqueues.auxlib"
local cs = require "cqueues.socket"
local http_tls = require "http.tls"
local connection_common = require "http.connection_common"
local h1_connection = require "http.h1_connection"
local h2_connection = require "http.h2_connection"
local openssl_ssl = require "openssl.ssl"
local openssl_ctx = require "openssl.ssl.context"
local openssl_verify_param = require "openssl.x509.verify_param"

local EOF = require "lpeg".P(-1)
local IPv4address = require "lpeg_patterns.IPv4".IPv4address
local IPv6addrz = require "lpeg_patterns.IPv6".IPv6addrz
local IPaddress = (IPv4address + IPv6addrz) * EOF

-- Create a shared 'default' TLS context
local default_ctx = http_tls.new_client_context()

local function negotiate(self, options, timeout)
	if cs.type(self) then -- passing cqueues socket
		self = connection_common.new(self, "client")
	end
	local tls = options.tls
	local version = options.version
	if tls then
		local ctx = options.ctx or default_ctx
		local ssl = openssl_ssl.new(ctx)
		local ip = options.host and IPaddress:match(options.host)
		if options.sendname ~= nil then
			if options.sendname then -- false indicates no sendname wanted
				ssl:setHostName(options.sendname)
			end
		elseif options.host and not ip then
			ssl:setHostName(options.host)
		end
		if http_tls.has_alpn then
			if version == nil then
				ssl:setAlpnProtos({"h2", "http/1.1"})
			elseif version == 1.1 then
				ssl:setAlpnProtos({"http/1.1"})
			elseif version == 2 then
				ssl:setAlpnProtos({"h2"})
			end
		end
		if version == 2 then
			ssl:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)
		end
		if options.host and http_tls.has_hostname_validation then
			local params = openssl_verify_param.new()
			if ip then
				params:setIP(options.host)
			else
				params:setHost(options.host)
			end
			-- Allow user defined params to override
			local old = ssl:getParam()
			old:inherit(params)
			ssl:setParam(old)
		end
		local ok, err, errno = self:starttls(ssl, timeout)
		if not ok then
			return nil, err, errno
		end
	end
	if version == nil then
		local ssl = self:checktls()
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
		return h1_connection.new_from_common(self, version)
	elseif version == 2 then
		return h2_connection.new_from_common(self, options.h2_settings)
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
		sendname = false;
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
