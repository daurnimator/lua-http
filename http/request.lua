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
		assert(uri_t.path == "", "CONNECT requests cannot have a path")
		assert(uri_t.query == nil, "CONNECT requests cannot have a query")
		assert(headers:has(":authority"), ":authority required for CONNECT requests")
	else
		headers:upsert(":authority", http_util.to_authority(host, port, scheme))
		local path = uri_t.path
		if path == nil or path == "" then
			path = "/"
		else
			path = http_util.encodeURI(path)
		end
		if uri_t.query then
			path = path .. "?" .. http_util.encodeURI(uri_t.query)
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
		headers:append(field, "basic " .. basexx.to_base64(uri_t.userinfo), true)
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

local function new_from_uri(uri)
	local uri_t = assert(uri_patt:match(uri), "invalid URI")
	return new_from_uri_t(uri_t)
end

local function new_connect(uri, connect_authority)
	local uri_t = assert(uri_patt:match(uri), "invalid URI")
	local headers = new_headers()
	headers:append(":authority", connect_authority)
	headers:append(":method", "CONNECT")
	return new_from_uri_t(uri_t, headers)
end

local function new_from_stream(stream)
	local host, port
	local ssl = stream:checktls()
	local request_headers = stream:get_headers()
	local scheme = request_headers:get(":scheme") or (ssl and "https" or "http")
	if request_headers:has(":authority") then
		host, port = http_util.split_authority(request_headers:get(":authority"), scheme)
	else
		local fam -- luacheck: ignore 231
		fam, host, port = stream:localname()
		host = ssl:getHostName() or host
	end

	local self = setmetatable({
		host = host;
		port = port;
		tls = ssl ~= nil; -- TODO: create ssl context?
		headers = request_headers;
		body = stream:read_body_to_tmpfile(request_headers); -- TODO: doesn't make sense for CONNECT
	}, request_mt)

	return self
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

function request_methods:to_url()
	-- TODO: userinfo section (username/password)
	local method = self.headers:get(":method")
	if method == "CONNECT" then
		local scheme = self.tls and "https" or "http"
		local authority = http_util.to_authority(self.host, self.port, scheme)
		return scheme .. "://" .. authority
	else
		local scheme = self.headers:get(":scheme")
		local authority = self.headers:get(":authority")
		if authority == nil then
			authority = http_util.to_authority(self.host, self.port, scheme)
		end
		local path = self.headers:get(":path")
		return scheme .. "://" .. authority .. path
	end
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
	local uri_t = assert(uri_ref:match(location), "invalid URI")
	local orig_scheme = self.headers:get(":scheme")
	if uri_t.scheme == nil then
		uri_t.scheme = orig_scheme
	end
	if uri_t.host == nil then
		uri_t.host, uri_t.port = http_util.split_authority(self.headers:get(":authority"), orig_scheme)
	end
	if uri_t.path ~= nil then
		uri_t.path = http_util.encodeURI(uri_t.path)
		if uri_t.path:sub(1, 1) ~= "/" then -- relative path
			local orig_target = self.headers:get(":path")
			local orig_path = assert(uri_ref:match(orig_target)).path
			orig_path = http_util.encodeURI(orig_path)
			uri_t.path = http_util.resolve_relative_path(orig_path, uri_t.path)
		end
	end
	local headers = self.headers:clone()
	local new_req = new_from_uri_t(uri_t, headers)
	new_req.expect_100_timeout = rawget(self, "expect_100_timeout")
	new_req.follow_redirects = rawget(self, "follow_redirects")
	new_req.max_redirects = max_redirects - 1
	new_req.post301 = rawget(self, "post301")
	new_req.post302 = rawget(self, "post302")
	if not new_req.tls and self.tls then
		--[[ RFC 7231 5.5.2: A user agent MUST NOT send a Referer header field in an
		unsecured HTTP request if the referring page was received with a secure protocol.]]
		headers:delete("referer")
	else
		headers:upsert("referer", self:to_url())
	end
	new_req.body = self.body
	-- Change POST requests to a body-less GET on redirect?
	local orig_status = orig_headers:get(":status")
	if (orig_status == "303"
		or (orig_status == "301" and not self.post301)
		or (orig_status == "302" and not self.post302)
		) and self.headers:get(":method") == "POST"
	then
		headers:upsert(":method", "GET")
		-- Remove headers that don't make sense without a body
		-- Headers that require a body
		headers:delete("transfer-encoding")
		headers:delete("content-length")
		-- Representation Metadata from RFC 7231 Section 3.1
		headers:delete("content-encoding")
		headers:delete("content-language")
		headers:delete("content-location")
		headers:delete("content-type")
		-- Other...
		if headers:get("expect") == "100-continue" then
			headers:delete("expect")
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

	do -- Write outgoing headers
		local ok, err, errno = stream:write_headers(self.headers, not self.body, deadline and (deadline-monotime()))
		if not ok then return nil, err, errno end
	end

	local headers
	if self.body then
		if self.headers:get("expect") == "100-continue" then
			-- Try to wait for 100-continue before proceeding
			if deadline then
				local err, errno
				headers, err, errno = stream:get_headers(math.min(self.expect_100_timeout, deadline-monotime()))
				if headers == nil and (err ~= ce.TIMEOUT or monotime() > deadline) then return nil, err, errno end
			else
				local err, errno
				headers, err, errno = stream:get_headers(self.expect_100_timeout)
				if headers == nil and err ~= ce.TIMEOUT then return nil, err, errno end
			end
		end
		if type(self.body) == "string" then
			local ok, err, errno = stream:write_body_from_string(self.body, deadline and (deadline-monotime()))
			if not ok then return nil, err, errno end
		elseif io.type(self.body) == "file" then
			local ok, err, errno = stream:write_body_from_file(self.body, deadline and (deadline-monotime()))
			if not ok then return nil, err, errno end
		elseif type(self.body) == "function" then
			-- call function to get body segments
			while true do
				local chunk = self.body()
				if chunk then
					local ok, err2, errno2 = stream:write_chunk(chunk, false, deadline and (deadline-monotime()))
					if not ok then return nil, err2, errno2 end
				else
					local ok, err2, errno2 = stream:write_chunk("", true, deadline and (deadline-monotime()))
					if not ok then return nil, err2, errno2 end
					break
				end
			end
		end
	end
	if not headers or headers:get(":status") == "100" then
		repeat -- Skip through 100-continue headers
			local err, errno
			headers, err, errno = stream:get_headers(deadline and (deadline-monotime()))
			if headers == nil then return nil, err, errno end
		until headers:get(":status") ~= "100"
	end

	if self.follow_redirects and headers:get(":status"):sub(1,1) == "3" then
		stream:shutdown()
		local new_req, err2, errno2 = self:handle_redirect(headers)
		if not new_req then return nil, err2, errno2 end
		return new_req:go(deadline and (deadline-monotime()))
	end

	return headers, stream
end

return {
	new_from_uri = new_from_uri;
	new_connect = new_connect;
	new_from_stream = new_from_stream;
	methods = request_methods;
	mt = request_mt;
}
