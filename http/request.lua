local lpeg = require "lpeg"
local uri_patts = require "lpeg_patterns.uri"
local basexx = require "basexx"
local client_connect = require "http.client".connect
local new_headers = require "http.headers".new
local http_util = require "http.util"
local version = require "http.version"
local monotime = require "cqueues".monotime
local ce = require "cqueues.errno"

local request_methods = {
	expect_100_timeout = 1;
	follow_redirects = true;
	max_redirects = 5;
	post301 = false;
	post302 = false;
}

local request_mt = {
	__name = "http.request";
	__index = request_methods;
}

local default_user_agent = string.format("%s/%s", version.name, version.version)

local EOF = lpeg.P(-1)
local uri_patt = uri_patts.uri * EOF
local uri_ref = uri_patts.uri_reference * EOF

local function new_from_uri_t(uri_t, headers)
	assert(type(uri_t) == "table")
	local scheme = assert(uri_t.scheme, "URI missing scheme")
	assert(scheme == "https" or scheme == "http" or scheme == "ws" or scheme == "wss", "scheme not valid")
	local host = tostring(assert(uri_t.host, "URI must include a host")) -- tostring required to e.g. convert lpeg_patterns IPv6 objects
	local port = uri_t.port or http_util.scheme_to_port[scheme]
	local is_connect -- CONNECT requests are a bit special, see http2 spec section 8.3
	if headers == nil then
		headers = new_headers()
		headers:append(":method", "GET")
		is_connect = false
	else
		is_connect = headers:get(":method") == "CONNECT"
	end
	if is_connect then
		assert(uri_t.path == nil or uri_t.path == "", "CONNECT requests cannot have a path")
		assert(uri_t.query == nil, "CONNECT requests cannot have a query")
		assert(headers:has(":authority"), ":authority required for CONNECT requests")
	else
		headers:upsert(":authority", http_util.to_authority(host, port, scheme))
		local path = uri_t.path
		if path == nil or path == "" then
			path = "/"
		end
		if uri_t.query then
			path = path .. "?" .. uri_t.query
		end
		headers:upsert(":path", path)
		headers:upsert(":scheme", scheme)
	end
	if uri_t.userinfo then
		local field
		if is_connect then
			field = "proxy-authorization"
		else
			field = "authorization"
		end
		local userinfo = http_util.decodeURIComponent(uri_t.userinfo) -- XXX: this doesn't seem right, but it's same behaviour as curl
		headers:append(field, "basic " .. basexx.to_base64(userinfo), true)
	end
	if not headers:has("user-agent") then
		headers:append("user-agent", default_user_agent)
	end
	local self = setmetatable({
		host = host;
		port = port;
		tls = (scheme == "https" or scheme == "wss");
		headers = headers;
		body = nil;
	}, request_mt)
	return self
end

local function new_from_uri(uri, ...)
	if type(uri) == "string" then
		uri = assert(uri_patt:match(uri), "invalid URI")
	end
	return new_from_uri_t(uri, ...)
end

local function new_connect(uri, connect_authority)
	local uri_t = assert(uri_patt:match(uri), "invalid URI")
	local headers = new_headers()
	headers:append(":authority", connect_authority)
	headers:append(":method", "CONNECT")
	return new_from_uri_t(uri_t, headers)
end

function request_methods:clone()
	return setmetatable({
		host = self.host;
		port = self.port;
		tls = self.tls;
		sendname = self.sendname;
		version = self.version;

		headers = self.headers:clone();
		body = self.body;

		expect_100_timeout = rawget(self, "expect_100_timeout");
		follow_redirects = rawget(self, "follow_redirects");
		max_redirects = rawget(self, "max_redirects");
		post301 = rawget(self, "post301");
		post302 = rawget(self, "post302");
	}, request_mt)
end

function request_methods:to_url(with_userinfo)
	local scheme = self.headers:get(":scheme")
	local method = self.headers:get(":method")
	local path
	if scheme == nil then
		scheme = self.tls and "https" or "http"
	end
	local authority
	local authorization_field
	if method == "CONNECT" then
		authorization_field = "proxy-authorization"
		path = ""
	else
		authority = self.headers:get(":authority")
		-- TODO: validate authority can fit in a url
		path = self.headers:get(":path")
		-- TODO: validate path is valid for uri?
		authorization_field = "authorization"
	end
	if authority == nil then
		authority = http_util.to_authority(self.host, self.port, scheme)
	end
	if with_userinfo and self.headers:has(authorization_field) then
		local authorization = self.headers:get(authorization_field)
		local auth_type, userinfo = authorization:match("^%s*(%S+)%s+(%S+)%s*$")
		if auth_type and auth_type:lower() == "basic" then
			userinfo = basexx.from_base64(userinfo)
			userinfo = http_util.encodeURI(userinfo)
			authority = userinfo .. "@" .. authority
		else
			error("authorization cannot be converted to uri")
		end
	end
	return scheme .. "://" .. authority .. path
end

function request_methods:new_stream(timeout)
	-- TODO: pooling
	local connection, err, errno = client_connect({
		host = self.host;
		port = self.port;
		tls = self.tls;
		sendname = self.sendname;
		version = self.version;
	}, timeout)
	if connection == nil then
		return nil, err, errno
	end
	return connection:new_stream()
end

function request_methods:handle_redirect(orig_headers)
	local max_redirects = self.max_redirects
	if max_redirects <= 0 then
		return nil, "maximum redirects exceeded", ce.ELOOP
	end
	local location = orig_headers:get("location")
	if not location then
		return nil, "missing location header for redirect", ce.EINVAL
	end
	local uri_t = uri_ref:match(location)
	if not uri_t then
		return nil, "invalid URI in location header", ce.EINVAL
	end
	local new_req = self:clone()
	new_req.max_redirects = max_redirects - 1
	local method = new_req.headers:get(":method")
	local is_connect = method == "CONNECT"
	local new_scheme = uri_t.scheme
	if new_scheme then
		if not is_connect then
			new_req.headers:upsert(":scheme", new_scheme)
		end
		if new_scheme == "https" or new_scheme == "wss" then
			new_req.tls = self.tls or true
		else
			new_req.tls = false
		end
	else
		if not is_connect then
			new_scheme = new_req.headers:get(":scheme")
		end
		if new_scheme == nil then
			new_scheme = self.tls and "https" or "http"
		end
	end
	local orig_target
	local target_authority
	if not is_connect then
		orig_target = self.headers:get(":path")
		orig_target = uri_ref:match(orig_target)
		if orig_target and orig_target.host then
			-- was originally a proxied request
			local new_authority
			if uri_t.host then -- we have a new host
				new_authority = http_util.to_authority(uri_t.host, uri_t.port, new_scheme)
				new_req.headers:upsert(":authority", new_authority)
			else
				new_authority = self.headers:get(":authority")
			end
			if new_authority == nil then
				new_authority = http_util.to_authority(self.host, self.port, new_scheme)
			end
			-- prefix for new target
			target_authority = new_scheme .. "://" .. new_authority
		end
	end
	if target_authority == nil and uri_t.host then
		-- we have a new host and it wasn't placed into :authority
		new_req.host = uri_t.host
		if not is_connect then
			new_req.headers:upsert(":authority", http_util.to_authority(uri_t.host, uri_t.port, new_scheme))
		end
		new_req.port = uri_t.port or http_util.scheme_to_port[new_scheme]
		new_req.sendname = nil
	end -- otherwise same host as original request; don't need change anything
	if is_connect then
		if uri_t.path ~= nil and uri_t.path ~= "" then
			return nil, "CONNECT requests cannot have a path", ce.EINVAL
		elseif uri_t.query ~= nil then
			return nil, "CONNECT requests cannot have a query", ce.EINVAL
		end
	else
		local new_path
		if uri_t.path == nil or uri_t.path == "" then
			new_path = "/"
		else
			new_path = uri_t.path
			if new_path:sub(1, 1) ~= "/" then -- relative path
				if not orig_target then
					return nil, "base path not valid for relative redirect", ce.EINVAL
				end
				local orig_path = orig_target.path or "/"
				new_path = http_util.resolve_relative_path(orig_path, new_path)
			end
		end
		if uri_t.query then
			new_path = new_path .. "?" .. uri_t.query
		end
		if target_authority then
			new_path = target_authority .. new_path
		end
		new_req.headers:upsert(":path", new_path)
	end
	if uri_t.userinfo then
		local field
		if is_connect then
			field = "proxy-authorization"
		else
			field = "authorization"
		end
		new_req.headers:upsert(field, "basic " .. basexx.to_base64(uri_t.userinfo), true)
	end
	if not new_req.tls and self.tls then
		--[[ RFC 7231 5.5.2: A user agent MUST NOT send a Referer header field in an
		unsecured HTTP request if the referring page was received with a secure protocol.]]
		new_req.headers:delete("referer")
	else
		new_req.headers:upsert("referer", self:to_url(false))
	end
	-- Change POST requests to a body-less GET on redirect?
	local orig_status = orig_headers:get(":status")
	if (orig_status == "303"
		or (orig_status == "301" and not self.post301)
		or (orig_status == "302" and not self.post302)
		) and method == "POST"
	then
		new_req.headers:upsert(":method", "GET")
		-- Remove headers that don't make sense without a body
		-- Headers that require a body
		new_req.headers:delete("transfer-encoding")
		new_req.headers:delete("content-length")
		-- Representation Metadata from RFC 7231 Section 3.1
		new_req.headers:delete("content-encoding")
		new_req.headers:delete("content-language")
		new_req.headers:delete("content-location")
		new_req.headers:delete("content-type")
		-- Other...
		local expect = new_req.headers:get("expect")
		if expect and expect:lower() == "100-continue" then
			new_req.headers:delete("expect")
		end
		new_req.body = nil
	end
	return new_req
end

function request_methods:set_body(body)
	self.body = body
	local length
	if type(self.body) == "string" then
		length = #body
	end
	if length then
		self.headers:upsert("content-length", string.format("%d", #body))
	end
	if not length or length > 1024 then
		self.headers:append("expect", "100-continue")
	end
end

function request_methods:go(timeout)
	local deadline = timeout and (monotime()+timeout)

	local stream do
		local err, errno
		stream, err, errno = self:new_stream(timeout)
		if stream == nil then return nil, err, errno end
	end

	local body = self.body

	do -- Write outgoing headers
		local ok, err, errno = stream:write_headers(self.headers, body == nil, deadline and deadline-monotime())
		if not ok then
			stream:shutdown()
			return nil, err, errno
		end
	end

	local headers
	if body then
		local expect = self.headers:get("expect")
		if expect and expect:lower() == "100-continue" then
			-- Try to wait for 100-continue before proceeding
			if deadline then
				local err, errno
				headers, err, errno = stream:get_headers(math.min(self.expect_100_timeout, deadline-monotime()))
				if headers == nil and (err ~= ce.ETIMEDOUT or monotime() > deadline) then
					stream:shutdown()
					return nil, err, errno
				end
			else
				local err, errno
				headers, err, errno = stream:get_headers(self.expect_100_timeout)
				if headers == nil and err ~= ce.ETIMEDOUT then
					stream:shutdown()
					return nil, err, errno
				end
			end
			if headers and headers:get(":status") ~= "100" then
				-- Don't send body
				body = nil
			end
		end
		if body then
			local ok, err, errno
			if type(body) == "string" then
				ok, err, errno = stream:write_body_from_string(body, deadline and deadline-monotime())
			elseif io.type(body) == "file" then
				ok, err, errno = body:seek("set")
				if ok then
					ok, err, errno = stream:write_body_from_file(body, deadline and deadline-monotime())
				end
			elseif type(body) == "function" then
				-- call function to get body segments
				while true do
					local chunk = body()
					if chunk then
						ok, err, errno = stream:write_chunk(chunk, false, deadline and deadline-monotime())
						if not ok then
							break
						end
					else
						ok, err, errno = stream:write_chunk("", true, deadline and deadline-monotime())
						break
					end
				end
			end
			if not ok then
				stream:shutdown()
				return nil, err, errno
			end
		end
	end
	if not headers or headers:get(":status") == "100" then
		repeat -- Skip through 100-continue headers
			local err, errno
			headers, err, errno = stream:get_headers(deadline and (deadline-monotime()))
			if headers == nil then
				stream:shutdown()
				return nil, err, errno
			end
		until headers:get(":status") ~= "100"
	end

	if self.follow_redirects and headers:get(":status"):sub(1,1) == "3" then
		stream:shutdown()
		local new_req, err2, errno2 = self:handle_redirect(headers)
		if not new_req then
			return nil, err2, errno2
		end
		return new_req:go(deadline and (deadline-monotime()))
	end

	return headers, stream
end

return {
	new_from_uri_t = new_from_uri_t;
	new_from_uri = new_from_uri;
	new_connect = new_connect;
	methods = request_methods;
	mt = request_mt;
}
