local monotime = require "cqueues".monotime
local cs = require "cqueues.socket"
local ce = require "cqueues.errno"
local http_tls = require "http.tls"
local new_h1_connection = require "http.h1_connection".new
local new_h2_connection = require "http.h2_connection".new

-- Create a shared 'default' TLS contexts
local default_h1_ctx = http_tls.new_client_context()
local default_h2_ctx
-- if ALPN is not supported; do not create h2 context
if http_tls.has_alpn then
	default_h1_ctx:setAlpnProtos({"http/1.1"})

	default_h2_ctx = http_tls.new_client_context()
	default_h2_ctx:setAlpnProtos({"h2", "http/1.1"})
end

local function onerror(socket, op, why, lvl) -- luacheck: ignore 212
	if why == ce.ETIMEDOUT then
		return why
	end
	return string.format("%s: %s", op, ce.strerror(why)), why
end

local function negotiate(s, options, timeout)
	local deadline = timeout and (monotime()+timeout)
	s:onerror(onerror)
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
		local ok, err, errno = s:starttls(tls, deadline and (deadline-monotime()))
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
