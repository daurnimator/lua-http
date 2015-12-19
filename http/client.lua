local monotime = require "cqueues".monotime
local cs = require "cqueues.socket"
local new_client_context = require "http.tls".new_client_context
local new_h1_connection = require "http.h1_connection".new
local new_h2_connection = require "http.h2_connection".new
local h2_errors = require "http.h2_error".errors

-- Create a shared 'default' TLS contexts
local default_h1_ctx = new_client_context()
local default_h2_ctx
-- if ALPN is not supported; do not create h2 context
if default_h1_ctx.setAlpnProtos then
	default_h2_ctx = new_client_context()
	default_h2_ctx:setAlpnProtos({"h2"})
end

local function connect(options, timeout)
	local deadline = timeout and (monotime()+timeout)
	local s = assert(cs.connect({
		host = options.host;
		port = options.port;
		sendname = options.sendname;
		v6only = options.v6only;
		nodelay = true;
	}))
	local tls = options.tls
	local version = options.version
	if tls then
		if tls == true then
			if version then
				if version < 2 then
					tls = default_h1_ctx
				else
					tls = assert(default_h2_ctx, "http2 TLS context unavailable")
				end
			else
				tls = default_h2_ctx or default_h1_ctx
			end
		end
		assert(s:starttls(tls, timeout))
	end
	if version == nil then
		if tls then
			local ssl = s:checktls()
			if ssl:getAlpnSelected() == "h2" then
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
		if tls then
			local ssl = s:checktls()
			if ssl:getAlpnSelected() ~= "h2" then
				h2_errors.PROTOCOL_ERROR("ALPN is not h2")
			end
		end
		return new_h2_connection(s, "client", options.h2_settings, deadline and (deadline-monotime()))
	else
		error("Unknown HTTP version: " .. tostring(version))
	end
end

return {
	connect = connect;
}
