--[[
Data structures useful for Cookies
RFC 6265
]]

local http_patts = require "lpeg_patterns.http"

local EOF = require "lpeg".P(-1)
local sane_cookie_date = http_patts.IMF_fixdate * EOF
local Cookie = http_patts.Cookie * EOF
local Set_Cookie = http_patts.Set_Cookie * EOF

local function parse_cookie(cookie_header)
	return Cookie:match(cookie_header)
end

local function parse_setcookie(setcookie_header)
	return Set_Cookie:match(setcookie_header)
end

local function canonicalise_host(domain)
	-- TODO!
	return domain
end

--[[
A string domain-matches a given domain string if at least one of the following
conditions hold:
  - The domain string and the string are identical. (Note that both the domain
    string and the string will have been canonicalized to lower case at this point.)
  - All of the following conditions hold:
	  - The domain string is a suffix of the string.
	  - The last character of the string that is not included in the domain string
	    is a %x2E (".") character.
	  - The string is a host name (i.e., not an IP address).
]]
local function domain_match(domain_string, str)
	return str == domain_string or (
		str:sub(-#domain_string) == domain_string
		and str:sub(-#domain_string-1, -#domain_string-1) == "."
		-- TODO: check if IP address?
	)
end

--[[ A request-path path-matches a given cookie-path if at least one of the following conditions holds:
  - The cookie-path and the request-path are identical.
  - The cookie-path is a prefix of the request-path, and the last
    character of the cookie-path is %x2F ("/").
  - The cookie-path is a prefix of the request-path, and the first
    character of the request-path that is not included in the cookie-path is a %x2F ("/") character.
]]
local function path_match(path, req_path)
	if path == req_path then
		return true
	elseif path == req_path:sub(1, #path) then
		if path:sub(-1, -1) == "/" then
			return true
		elseif req_path:sub(#path + 1, #path + 1) == "/" then
			return true
		end
	end
	return false
end

local cookie_methods = {}
local cookie_mt = {
	__name = "http.cookie.cookie";
	__index = cookie_methods;
}

local store_methods = {
	time = function() return os.time() end;
}

local store_mt = {
	__name = "http.cookie.store";
	__index = store_methods;
}

local function new_store()
	return setmetatable({
		domains = {};
	}, store_mt)
end

function store_methods:store(req_domain, req_path, req_is_http, name, value, params)
	assert(type(req_domain) == "string")
	assert(type(req_path) == "string")
	assert(type(name) == "string")
	assert(type(value) == "string")
	assert(type(params) == "table")

	local now = self.time()

	req_domain = canonicalise_host(req_domain)

	-- RFC 6265 Section 5.3
	local cookie = setmetatable({
		name = name;
		value = value;
		expiry_time = math.huge;
		domain = req_domain;
		path = nil;
		creation_time = now;
		last_access_time = now;
		persistent = false;
		host_only = true;
		secure_only = not not params.secure;
		http_only = not not params.httponly;
	}, cookie_mt)

	-- If a cookie has both the Max-Age and the Expires attribute, the Max-
	-- Age attribute has precedence and controls the expiration date of the
	-- cookie.
	local max_age = params["max-age"]
	if max_age and max_age:find("^%-?[0-9]+$") then
		max_age = tonumber(max_age, 10)
		cookie.persistent = true
		if max_age <= 0 then
			cookie.expiry_time = -math.huge
		else
			cookie.expiry_time = now + max_age
		end
	elseif params.expires then
		local date = sane_cookie_date:match(params.expires)
		if date then
			cookie.persistent = true
			cookie.expiry_time = os.time(date)
		end
	end

	local domain = params.domain or "";

	-- If the first character of the attribute-value string is %x2E ("."):
	-- Let cookie-domain be the attribute-value without the leading %x2E (".") character.
	if domain:sub(1, 1) == "." then
		domain = domain:sub(2)
	end

	-- Convert the cookie-domain to lower case.
	domain = canonicalise_host(domain)

	-- If the domain-attribute is non-empty:
	if #domain > 0 then
		-- If the canonicalized request-host does not domain-match the
		-- domain-attribute:
		if not domain_match(domain, req_domain) then
			-- Ignore the cookie entirely and abort these steps.
			return false
		else
			-- Set the cookie's host-only-flag to false.
			cookie.host_only = false
			-- Set the cookie's domain to the domain-attribute.
			cookie.domain = domain
		end
	end

	-- RFC 6265 Section 5.2.4
	-- If the attribute-value is empty or if the first character of the
	-- attribute-value is not %x2F ("/")
	local path = params.path or ""
	if path:sub(1, 1) ~= "/" then
		-- Let cookie-path be the default-path.
		local default_path
		-- RFC 6265 Section 5.1.4
		-- Let uri-path be the path portion of the request-uri if such a
		-- portion exists (and empty otherwise).  For example, if the
		-- request-uri contains just a path (and optional query string),
		-- then the uri-path is that path (without the %x3F ("?") character
		-- or query string), and if the request-uri contains a full
		-- absoluteURI, the uri-path is the path component of that URI.

		-- If the uri-path is empty or if the first character of the uri-
		-- path is not a %x2F ("/") character, output %x2F ("/") and skip
		-- the remaining steps.
		-- If the uri-path contains no more than one %x2F ("/") character,
		-- output %x2F ("/") and skip the remaining step.
		if req_path:sub(1, 1) ~= "/" or not req_path:find("/", 2, true) then
			default_path = "/"
		else
			-- Output the characters of the uri-path from the first character up
			-- to, but not including, the right-most %x2F ("/").
			default_path = req_path:match("^([^?]*)/")
		end
		cookie.path = default_path
	else
		cookie.path = path
	end

	-- If the cookie was received from a "non-HTTP" API and the
	-- cookie's http-only-flag is set, abort these steps and ignore the
	-- cookie entirely.
	if not req_is_http and cookie.http_only then
		return false
	end

	if cookie.expiry_time < now then
		-- This was all just a trigger to delete the old cookie
		self:remove(cookie.domain, cookie.path, cookie.name)
	else
		-- Insert the newly created cookie into the cookie store.
		local domain_cookies = self.domains[cookie.domain]
		if domain_cookies == nil then
			domain_cookies = {}
			self.domains[cookie.domain] = domain_cookies
		end
		local path_cookies = domain_cookies[cookie.path]
		if path_cookies == nil then
			path_cookies = {}
			domain_cookies[cookie.path] = path_cookies
		end

		local old_cookie = path_cookies[cookie.name]
		-- If the cookie store contains a cookie with the same name,
		-- domain, and path as the newly created cookie:
		if old_cookie then
			-- If the newly created cookie was received from a "non-HTTP"
			-- API and the old-cookie's http-only-flag is set, abort these
			-- steps and ignore the newly created cookie entirely.
			if not req_is_http and old_cookie.http_only then
				return false
			end

			-- Update the creation-time of the newly created cookie to
			-- match the creation-time of the old-cookie.
			cookie.creation_time = old_cookie.creation_time

			-- Remove the old-cookie from the cookie store.
			path_cookies[cookie.name] = nil
		end

		path_cookies[cookie.name] = cookie
	end

	return true
end

function store_methods:get(domain, path, name)
	assert(type(domain) == "string")
	assert(type(path) == "string")
	assert(type(name) == "string")
	local domain_cookies = self.domains[domain]
	if domain_cookies then
		local path_cookies = domain_cookies[path]
		if path_cookies then
			local cookie = path_cookies[name]
			if cookie then
				return cookie.value
			end
		end
	end
	return nil
end

function store_methods:remove(domain, path, name)
	assert(type(domain) == "string")
	assert(type(path) == "string" or (path == nil and name == nil))
	assert(type(name) == "string" or name == nil)
	local domain_cookies = self.domains[domain]
	if not domain_cookies then
		return
	end
	if path == nil then
		-- Delete whole domain
		self.domains[domain] = nil
	else
		local path_cookies = domain_cookies[path]
		if path_cookies then
			if name == nil then
				-- Delete all names at path
				domain_cookies[path] = nil
				if next(domain_cookies) == nil then
					self.domains[domain] = nil
				end
			else
				-- Delete singular cookie
				local cookie = path_cookies[name]
				if cookie then
					path_cookies[name] = nil
					if next(path_cookies) == nil then
						domain_cookies[path] = nil
						if next(domain_cookies) == nil then
							self.domains[domain] = nil
						end
					end
				end
			end
		end
	end
end

--[[ The user agent SHOULD sort the cookie-list in the following order:
  - Cookies with longer paths are listed before cookies with shorter paths.
  - Among cookies that have equal-length path fields, cookies with earlier
	creation-times are listed before cookies with later creation-times.
]]
local function cookie_cmp(a, b)
	if #a.path ~= #b.path then
		return #a.path > #b.path
	end
	if a.creation_time ~= b.creation_time then
		return a.creation_time < b.creation_time
	end
	-- Now order doesn't matter, but have to be consistent for table.sort:
	-- use the fields that make a cookie unique
	if a.domain ~= b.domain then
		return a.domain < b.domain
	end
	return a.name < b.name
end

local function cookie_match(cookie, req_domain, req_path, req_is_http, req_is_secure)
	-- req_domain should be already canonicalized

	if cookie.host_only then -- Either:
		-- The cookie's host-only-flag is true and the canonicalized
		-- request-host is identical to the cookie's domain.
		if cookie.domain ~= req_domain then
			return false
		end
	else -- Or:
		-- The cookie's host-only-flag is false and the canonicalized
		-- request-host domain-matches the cookie's domain.
		if not domain_match(cookie.domain, req_domain) then
			return false
		end
	end

	if not path_match(cookie.path, req_path) then
		return false
	end

	-- If the cookie's http-only-flag is true, then exclude the
	-- cookie if the cookie-string is being generated for a "non-
	-- HTTP" API (as defined by the user agent).
	if cookie.http_only and not req_is_http then
		return false
	end

	if cookie.secure_only and not req_is_secure then
		return false
	end

	return true
end

function store_methods:lookup(req_domain, req_path, req_is_http, req_is_secure)
	assert(type(req_domain) == "string")
	assert(type(req_path) == "string")
	local now = self.time()
	local list = {}
	local n = 0
	for _, domain_cookies in pairs(self.domains) do
		for _, path_cookies in pairs(domain_cookies) do
			for _, cookie in pairs(path_cookies) do
				if cookie.expiry_time < now then
					self:clean()
				elseif cookie_match(cookie, req_domain, req_path, req_is_http, req_is_secure) then
					cookie.last_access_time = now
					n = n + 1
					list[n] = cookie
				end
			end
		end
	end
	table.sort(list, cookie_cmp)
	for i=1, n do
		local cookie = list[i]
		-- TODO: validate?
		list[i] = cookie.name .. "=" .. cookie.value
	end
	return table.concat(list, "; ", 1, n)
end

function store_methods:clean()
	local now = self.time()
	for domain, domain_cookies in pairs(self.domains) do
		for path, path_cookies in pairs(domain_cookies) do
			for name, cookie in pairs(path_cookies) do
				if cookie.expiry_time < now then
					path_cookies[name] = nil
				end
			end
			if next(path_cookies) == nil then
				domain_cookies[path] = nil
			end
		end
		if next(domain_cookies) == nil then
			self.domains[domain] = nil
		end
	end
	return true
end

return {
	parse_cookie = parse_cookie;
	parse_setcookie = parse_setcookie;

	new_store = new_store;
	store_mt = store_mt;
	store_methods = store_methods;
}
