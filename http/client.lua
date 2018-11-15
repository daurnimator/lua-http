local monotime = require "cqueues".monotime
local ca = require "cqueues.auxlib"
local ce = require "cqueues.errno"
local cs = require "cqueues.socket"
local cqueues_dns = require "cqueues.dns"
local cqueues_dns_record = require "cqueues.dns.record"
local http_tls = require "http.tls"
local http_util = require "http.util"
local connection_common = require "http.connection_common"
local onerror = connection_common.onerror
local new_h1_connection = require "http.h1_connection".new
local new_h2_connection = require "http.h2_connection".new
local lpeg = require "lpeg"
local IPv4_patts = require "lpeg_patterns.IPv4"
local IPv6_patts = require "lpeg_patterns.IPv6"
local openssl_ssl = require "openssl.ssl"
local openssl_ctx = require "openssl.ssl.context"
local openssl_verify_param = require "openssl.x509.verify_param"

local AF_UNSPEC = cs.AF_UNSPEC
local AF_UNIX = cs.AF_UNIX
local AF_INET = cs.AF_INET
local AF_INET6 = cs.AF_INET6

local DNS_CLASS_IN = cqueues_dns_record.IN
local DNS_TYPE_A = cqueues_dns_record.A
local DNS_TYPE_AAAA = cqueues_dns_record.AAAA
local DNS_TYPE_CNAME = cqueues_dns_record.CNAME

local EOF = lpeg.P(-1)
local IPv4address = IPv4_patts.IPv4address * EOF
local IPv6addrz = IPv6_patts.IPv6addrz * EOF

-- Create a shared 'default' TLS context
local default_ctx = http_tls.new_client_context()

local function negotiate(s, options, timeout)
	s:onerror(onerror)
	local tls = options.tls
	local version = options.version
	if tls then
		local ctx = options.ctx or default_ctx
		local ssl = openssl_ssl.new(ctx)
		local host = options.host
		local host_is_ip = host and http_util.is_ip(host)
		local sendname = options.sendname
		if sendname == nil and not host_is_ip and host then
			sendname = host
		end
		if sendname then -- false indicates no sendname wanted
			ssl:setHostName(sendname)
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
		if host and http_tls.has_hostname_validation then
			local params = openssl_verify_param.new()
			if host_is_ip then
				params:setIP(host)
			else
				params:setHost(host)
			end
			-- Allow user defined params to override
			local old = ssl:getParam()
			old:inherit(params)
			ssl:setParam(old)
		end
		local ok, err, errno = s:starttls(ssl, timeout)
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

-- `type` parameter is what sort of records you want to find could be "A" or
-- "AAAA" or `nil` if you want to filter yourself e.g. to implement
-- https://www.ietf.org/archive/id/draft-vavrusa-dnsop-aaaa-for-free-00.txt
local function each_matching_record(pkt, name, type)
	-- First need to do CNAME chasing
	local params = {
		section = "answer";
		class = DNS_CLASS_IN;
		type = DNS_TYPE_CNAME;
		name = name .. ".";
	}
	for _=1, 8 do -- avoid cname loops
		-- Ignores any CNAME record past the first (which should never occur anyway)
		local func, state, first = pkt:grep(params)
		local record = func(state, first)
		if record == nil then
			-- Not found
			break
		end
		params.name = record:host()
	end
	params.type = type
	return pkt:grep(params)
end

local function dns_lookup(records, dns_resolver, host, port, query_type, filter_type, timeout)
	local packet = dns_resolver:query(host, query_type, nil, timeout)
	if not packet then
		return
	end
	for rec in each_matching_record(packet, host, filter_type) do
		local t = rec:type()
		if t == DNS_TYPE_AAAA then
			records:add_v6(rec:addr(), port)
		elseif t == DNS_TYPE_A then
			records:add_v4(rec:addr(), port)
		end
	end
end

local records_methods = {}
local records_mt = {
	__name = "http.client.records";
	__index = records_methods;
}

local function new_records()
	return setmetatable({
		n = 0;
		nil -- preallocate space for one
	}, records_mt)
end

function records_mt:__len()
	return self.n
end

local record_ipv4_methods = {
	family = AF_INET;
}
local record_ipv4_mt = {
	__name = "http.client.record.ipv4";
	__index = record_ipv4_methods;
}
function records_methods:add_v4(addr, port)
	local n = self.n + 1
	self[n] = setmetatable({ addr = addr, port = port }, record_ipv4_mt)
	self.n = n
end

local record_ipv6_methods = {
	family = AF_INET6;
}
local record_ipv6_mt = {
	__name = "http.client.record.ipv6";
	__index = record_ipv6_methods;
}
function records_methods:add_v6(addr, port)
	if type(addr) == "string" then
		-- Normalise
		addr = assert(IPv6addrz:match(addr))
	elseif getmetatable(addr) ~= IPv6_patts.IPv6_mt then
		error("invalid argument")
	end
	addr = tostring(addr)
	local n = self.n + 1
	self[n] = setmetatable({ addr = addr, port = port }, record_ipv6_mt)
	self.n = n
end

local record_unix_methods = {
	family = AF_UNIX;
}
local record_unix_mt = {
	__name = "http.client.record.unix";
	__index = record_unix_methods;
}
function records_methods:add_unix(path)
	local n = self.n + 1
	self[n] = setmetatable({ path = path }, record_unix_mt)
	self.n = n
end

function records_methods:remove_family(family)
	if family == nil then
		family = AF_UNSPEC
	end

	for i=self.n, 1, -1 do
		if self[i].family == family then
			table.remove(self, i)
			self.n = self.n - 1
		end
	end
end

local function lookup_records(options, timeout)
	local family = options.family
	if family == nil then
		family = AF_UNSPEC
	end

	local records = new_records()

	local path = options.path
	if path then
		if family ~= AF_UNSPEC and family ~= AF_UNIX then
			error("cannot use .path with non-unix address family")
		end
		records:add_unix(path)
		return records
	end

	local host = options.host
	local port = options.port

	local ipv4 = IPv4address:match(host)
	if ipv4 then
		records:add_v4(host, port)
		return records
	end

	local ipv6 = IPv6addrz:match(host)
	if ipv6 then
		records:add_v6(ipv6, port)
		return records
	end

	local dns_resolver = options.dns_resolver or cqueues_dns.getpool()
	if family == AF_UNSPEC then
		local deadline = timeout and monotime()+timeout
		dns_lookup(records, dns_resolver, host, port, DNS_TYPE_AAAA, nil, timeout)
		dns_lookup(records, dns_resolver, host, port, DNS_TYPE_A, nil, deadline and deadline-monotime())
	elseif family == AF_INET then
		dns_lookup(records, dns_resolver, host, port, DNS_TYPE_A, DNS_TYPE_A, timeout)
	elseif family == AF_INET6 then
		dns_lookup(records, dns_resolver, host, port, DNS_TYPE_AAAA, DNS_TYPE_AAAA, timeout)
	end

	return records
end

local function connect(options, timeout)
	local deadline = timeout and monotime()+timeout

	local records = lookup_records(options, timeout)

	local bind = options.bind
	if bind ~= nil then
		assert(type(bind) == "string")
		local bind_address, bind_port = bind:match("^(.-):(%d+)$")
		if bind_address then
			bind_port = tonumber(bind_port, 10)
		else
			bind_address = bind
		end
		local ipv6 = bind_address:match("^%[([:%x]+)%]$")
		if ipv6 then
			bind_address = ipv6
		end
		bind = {
			address = bind_address;
			port = bind_port;
		}
	end

	local connect_params = {
		family = nil;
		host = nil;
		port = nil;
		path = nil;
		bind = bind;
		sendname = false;
		v6only = options.v6only;
		nodelay = true;
	}

	local lasterr, lasterrno = "The name does not resolve for the supplied parameters"
	local i = 1
	while i <= records.n do
		local rec = records[i]
		connect_params.family = rec.family;
		connect_params.host = rec.addr;
		connect_params.port = rec.port;
		connect_params.path = rec.path;
		local s
		s, lasterr, lasterrno = ca.fileresult(cs.connect(connect_params))
		if s then
			local c
			c, lasterr, lasterrno = negotiate(s, options, deadline and deadline-monotime())
			if c then
				-- Force TCP connect to occur
				local ok
				ok, lasterr, lasterrno = c:connect(deadline and deadline-monotime())
				if ok then
					return c
				end
				c:close()
			else
				s:close()
			end
		end
		if lasterrno == ce.EAFNOSUPPORT then
			-- If an address family is not supported then entirely remove that
			-- family from candidate records
			records:remove_family(connect_params.family)
		else
			i = i + 1
		end
	end
	return nil, lasterr, lasterrno
end

return {
	negotiate = negotiate;
	connect = connect;
}
