--[[
This module implements a subset of SOCKS as defined in RFC 1928.

SOCKS5 has different authentication mechanisms,
currently this code only supports username+password auth (defined in RFC 1929).

URI format is taken from curl:
  - socks5:// is SOCKS5, resolving the authority locally
  - socks5h:// is SOCK5, but let the proxy resolve the hostname
]]

local monotime = require "cqueues".monotime
local ce = require "cqueues.errno"
local cs = require "cqueues.socket"
local spack = string.pack or require "compat53.string".pack
local sunpack = string.unpack or require "compat53.string".unpack
local IPv4 = require "lpeg_patterns.IPv4"
local IPv6 = require "lpeg_patterns.IPv6"
local uri_patts = require "lpeg_patterns.uri"
local http_util = require "http.util"
local client = require "http.client"

local EOF = require "lpeg".P(-1)
local IPv4address = require "lpeg_patterns.IPv4".IPv4address * EOF
local IPv6address = require "lpeg_patterns.IPv6".IPv6address * EOF

-- RFC 1929
local function username_password_auth(s, username, password, deadline)
	do
		local data = spack("Bs1s1", 1, username, password)
		local ok, err, errno = s:xwrite(data, "n", deadline and deadline-monotime())
		if not ok then
			return nil, err or ce.EPIPE, errno
		end
	end
	do
		local version, err, errno = s:xread(1, deadline and deadline-monotime())
		if not version then
			return nil, err or ce.EPIPE, errno
		end
		if version ~= "\1" then
			return nil, "invalid username/password auth version"
		end
	end
	do
		local ok, err, errno = s:xread(1, deadline and deadline-monotime())
		if not ok then
			return nil, err or ce.EPIPE, errno
		end
		if ok ~= "\0" then
			return nil, ce.EACCES
		end
	end
	return true
end

local function socks5_negotiate_deadline(s, options, deadline)
	local available_auth_methods = {
		"\0", ["\0"] = true;
	}
	if options.username then
		table.insert(available_auth_methods, "\2")
		available_auth_methods["\2"] = true
	end
	do
		local data = "\5"..string.char(#available_auth_methods)..table.concat(available_auth_methods)
		local ok, err, errno = s:xwrite(data, "n", deadline and deadline-monotime())
		if not ok then
			return nil, err or ce.EPIPE, errno
		end
	end
	do
		local byte, err, errno = s:xread(1, deadline and deadline-monotime())
		if not byte then
			return nil, err or ce.EPIPE, errno
		elseif byte ~= "\5" then
			return nil, "not SOCKS5"
		end
	end
	local auth_method do
		local err, errno
		auth_method, err, errno = s:xread(1, deadline and deadline-monotime())
		if not auth_method then
			return nil, err or ce.EPIPE, errno
		end
		if available_auth_methods[auth_method] == nil then
			return nil, "Unknown authentication method"
		end
	end
	if auth_method == "\0" then -- luacheck: ignore 542
		-- do nothing
	elseif auth_method == "\2" then
		local ok, err, errno = username_password_auth(s, options.username, options.password, deadline)
		if not ok then
			return nil, err, errno
		end
	else
		error("unreachable")
	end
	do
		local host = options.host
		local port = tonumber(options.port)
		local data
		if getmetatable(host) == IPv4.IPv4_mt then
			data = spack(">BBx Bc4I2", 5, 1, 1, host:binary(), port)
		elseif getmetatable(host) == IPv6.IPv6_mt then
			data = spack(">BBx Bc16I2", 5, 1, 4, host:binary(), port)
		else -- domain name
			data = spack(">BBx Bs1I2", 5, 1, 3, host, port)
		end
		local ok, err, errno = s:xwrite(data, "n", deadline and deadline-monotime())
		if not ok then
			return nil, err or ce.EPIPE, errno
		end
	end
	do
		local byte, err, errno = s:xread(1, deadline and deadline-monotime())
		if not byte then
			return nil, err or ce.EPIPE, errno
		elseif byte ~= "\5" then
			return nil, "not SOCKS5"
		end
	end
	do
		local code, err, errno = s:xread(1, deadline and deadline-monotime())
		if not code then
			return nil, err or ce.EPIPE, errno
		elseif code ~= "\0" then
			local num_code = code:byte()
			if num_code == 1 then
				err = "general SOCKS server failure"
			elseif num_code == 2 then
				err = "connection not allowed by ruleset"
				errno = ce.EACCES
			elseif num_code == 3 then
				err = "Network unreachable"
				errno = ce.ENETUNREACH
			elseif num_code == 4 then
				err = "Host unreachable"
				errno = ce.EHOSTUNREACH
			elseif num_code == 5 then
				err = "Connection refused"
				errno = ce.ECONNREFUSED
			elseif num_code == 6 then
				err = "TTL expired"
				errno = ce.ETIMEDOUT
			elseif num_code == 7 then
				err = "Command not supported"
				errno = ce.EOPNOTSUPP
			elseif num_code == 8 then
				err = "Address type not supported"
				errno = ce.EAFNOSUPPORT
			else
				err = "Unknown code"
			end
			return nil, string.format("SOCKS5 error %d: %s", code, err), errno
		end
	end
	do
		local byte, err, errno = s:xread(1, deadline and deadline-monotime())
		if not byte then
			return nil, err or ce.EPIPE, errno
		elseif byte ~= "\0" then
			return nil, "Reserved field set to non-zero"
		end
	end
	local dst_fam, dst_host, dst_port
	do
		local atype, err, errno = s:xread(1, deadline and deadline-monotime())
		if not atype then
			return nil, err or ce.EPIPE, errno
		end
		if atype == "\1" then
			local ipv4
			ipv4, err, errno = s:xread(4, deadline and deadline-monotime())
			if not ipv4 then
				return nil, err or ce.EPIPE, errno
			end
			dst_fam = cs.AF_INET
			local o1, o2, o3, o4 = ipv4:byte(1, 4)
			dst_host = string.format("%d.%d.%d.%d", o1, o2, o3, o4)
		elseif atype == "\4" then
			local ipv6
			ipv6, err, errno = s:xread(16, deadline and deadline-monotime())
			if not ipv6 then
				return nil, err or ce.EPIPE, errno
			end
			dst_fam = cs.AF_INET6
			local o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12, o13, o14, o15, o16 =
				ipv6:byte(1, 16)
			dst_host = string.format("%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
				o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12, o13, o14, o15, o16)
		elseif atype == "\3" then
			local len
			len, err, errno = s:xread(1, deadline and deadline-monotime())
			if not len then
				return nil, err or ce.EPIPE, errno
			end
			dst_fam = cs.AF_UNSPEC
			dst_host, err, errno = s:xread(string.byte(len), deadline and deadline-monotime())
			if not dst_host then
				return nil, err or ce.EPIPE, errno
			end
		else
			return nil, "Unknown address type", ce.EAFNOSUPPORT
		end
	end
	do
		local dst_port_bin, err, errno = s:xread(2, deadline and deadline-monotime())
		if not dst_port_bin then
			return nil, err or ce.EPIPE, errno
		end
		dst_port = sunpack(">I2", dst_port_bin)
	end
	return dst_fam, dst_host, dst_port
end

-- Wrapper that takes timeout instead of deadline
local function socks5_negotiate(s, options, timeout)
	return socks5_negotiate_deadline(s, options, timeout and (monotime()+timeout))
end

local function connect(socks_uri, options, timeout)
	local deadline = timeout and (monotime()+timeout)
	local uri_t = assert(uri_patts.uri:match(socks_uri), "invalid URI")
	local resolve_locally
	if uri_t.scheme == "socks5" then
		resolve_locally = true
	elseif uri_t.scheme == "socks5h" then
		resolve_locally = false
	else
		error("only SOCKS5 proxys supported")
	end
	assert(uri_t.path == "", "path not expected")
	local username, password
	if uri_t.userinfo then
		username, password = uri_t.userinfo:match("^([^:]*):(.*)$")
		username = http_util.decodeURIComponent(username)
		password = http_util.decodeURIComponent(password)
	end
	local s do
		-- TODO: https://github.com/wahern/cqueues/issues/124
		local errno
		s, errno = cs.connect {
			family = options.family;
			host = uri_t.host;
			port = uri_t.port;
			-- the sendname that will be used for the HTTP connection (not for the SOCKS connection)
			sendname = options.sendname or options.host or false;
			v6only = options.v6only;
			nodelay = true;
		}
		if s == nil then
			return nil, ce.strerror(errno), errno
		end
	end
	local dst_fam, dst_host, dst_port do
		local host = IPv4address:match(options.host)
			or IPv6address:match(options.host)
		if host == nil then
			if resolve_locally then
				error("NYI")
			else
				host = options.host
			end
		end
		dst_fam, dst_host, dst_port = socks5_negotiate_deadline(s, {
			host = host;
			port = options.port;
			username = username;
			password = password;
		}, deadline)
		if not dst_fam then
			s:close()
			return nil, dst_host, dst_port
		end
	end
	local conn, err, errno = client.negotiate(s, options, deadline and deadline-monotime())
	if not conn then
		s:close()
		return nil, err, errno
	end
	-- TODO: return dst_fam, dst_host, dst_port somehow
	return conn
end

return {
	socks5_negotiate = socks5_negotiate;
	connect = connect;
}
