local http_patts = require "lpeg_patterns.http"
local util = require "http.util"
local psl = require "psl"

local function parse_set_cookie(text_cookie, host, path, time)
	assert(time, "missing time value for cookie parsing")
	local key, value, matched_cookie = assert(http_patts.Set_Cookie:match(text_cookie, 1))
	local cookie = {
		creation = time;
		last_access = time;
		persistent = not not (matched_cookie.expires or matched_cookie["max-age"]);
		domain = matched_cookie.domain or host;
		path = matched_cookie.path or path;
		secure = matched_cookie.secure or false;
		http_only = matched_cookie.httponly or false;
		key = key;
		value = value;
		host_only = not not matched_cookie.domain;
		same_site = matched_cookie.same_site;
	}
	local age = matched_cookie["max-age"]
	if age then
		local negative = age:match("^-")
		if negative then
			-- RFC 6265 section 5.2.2 - if the value when converted to an
			-- integer is negative, the expiration should be the earliest
			-- representable expiration time.
			cookie.expires = 0
		else
			cookie.expires = time + tonumber(age)
		end
	else -- luacheck: ignore
		-- ::TODO:: make use of `expires` cookie value
	end
	return cookie
end

local function bake_cookie(data)
	assert(type(data.key) == "string", "`key` field for cookie must be string")
	assert(type(data.value) == "string", "`value` field for cookie must be string")
	local cookie = {data.key .. "=" .. data.value}
	if data.expires then
		cookie[#cookie + 1] = "; Expires=" .. util.imf_date(data.expires)
	end
	if data.max_age then
		cookie[#cookie + 1] = "; Max-Age=" .. string.format("%d", data.max_age)
	end
	if data.domain then
		cookie[#cookie + 1] = "; Domain=" .. data.domain
	end
	if data.path then
		cookie[#cookie + 1] = "; Path=" .. util.encodeURI(data.path)
	end
	if data.secure then
		cookie[#cookie + 1] = "; Secure"
	end
	if data.http_only then
		cookie[#cookie + 1] = "; HttpOnly"
	end
	-- This component is not a part of the RFC 6265 specification for the
	-- headers, but is instead from a draft of another RFC that builds on the
	-- original one.
	-- https://tools.ietf.org/html/draft-ietf-httpbis-cookie-same-site-00#section-4.1
	if data.same_site then
		local v
		if data.same_site:lower() == "strict" then
			v = "; SameSite=Strict"
		elseif data.same_site:lower() == "lax" then
			v = "; SameSite=Lax"
		else
			error('invalid value for same_site, expected "Strict" or "Lax"')
		end
		cookie[#cookie + 1] = v
	end
	return table.concat(cookie)
end

local function iterate_cookies(cookie)
	return pairs(assert(http_patts.Cookie:match(cookie, 1), "improper Cookie header format"))
end

local function parse_cookies(cookie)
	local cookies = {}
	for k, v in iterate_cookies(cookie) do
		cookies[k] = v
		cookies[#cookies + 1] = {k, v}
	end
	table.sort(cookies, function(t1, t2)
		return t1[1] < t2[1]
	end)
	return cookies
end

local cookiejar_methods = {}
if psl.latest then
	cookiejar_methods.psl_object = psl.latest()
else
	cookiejar_methods.psl_object = psl.builtin()
end
local cookiejar_mt = {
	__name = "http.cookies.cookiejar";
	__index = cookiejar_methods;
}

local function new_cookiejar()
	return setmetatable({cookies={}}, cookiejar_mt)
end

function cookiejar_methods:add(cookie, time)
	cookie.last_access = time or os.time()
	local domain, path, key = cookie.domain, cookie.path, cookie.key
	local cookies = self.cookies
	if cookies[domain] and cookies[domain][path] then
		local old_cookie = cookies[domain][path][key]
		if old_cookie then
			cookie.creation = old_cookie.creation
		end
	end

	local old_cookie = self:get(cookie.domain, cookie.path, cookie.key)
	if old_cookie then
		self:remove_cookie(old_cookie)
	end
	if cookie.persistent then
		local cookie_exp_time = cookie.expires
		local inserted = false
		for i=1, #cookies do
			-- insert into first spot where cookie expires after
			if cookies[i].expires < cookie_exp_time then
				inserted = true
				table.insert(cookies, i, cookie)
			end
		end
		if not inserted then
			cookies[#cookies + 1] = cookie
		end
	else
		cookie.expires = math.huge
		table.insert(cookies, 1, cookie)
	end

	local by_domain = cookies[domain]
	if not by_domain then
		by_domain = {}
		cookies[domain] = by_domain
	end
	local by_path = by_domain[path]
	if not by_path then
		by_path = {}
		by_domain[path] = by_path
	end
	by_path[key] = cookie
end

function cookiejar_methods:get_expired(time)
	time = time or os.time()
	local cookies = self.cookies
	local returned_cookies = {}
	for i=#cookies, 1, -1 do
		local cookie = cookies[i]
		if cookie.expires > time then
			break
		end
		returned_cookies[#returned_cookies + 1] = cookie
	end
	return returned_cookies
end

function cookiejar_methods:get(domain, path, key)
	local cookies = self.cookies
	local by_domain = cookies[domain]
	if not by_domain then
		return
	end
	local by_path = by_domain[path]
	if not by_path then
		return
	end
	return by_path[key]
end

local function clear_holes(tbl, n)
	local start_hole = 0
	for i=1, n do
		if tbl[i] and start_hole ~= 0 then
			tbl[start_hole] = tbl[i]
			tbl[i] = nil
			start_hole = start_hole + 1
		elseif not tbl[i] and start_hole == 0 then
			start_hole = i
		end
	end
end

function cookiejar_methods:remove_cookie(cookie)
	local cookies = self.cookies
	for i=1, #cookies do
		if cookie == cookies[i] then
			table.remove(cookies, i)
			cookies[cookie.domain][cookie.path][cookie.key] = nil
			return true
		end
	end
	return false
end

function cookiejar_methods:remove_cookies(cookies)
	local cookie_hashes = {}
	for _, key in pairs(cookies) do
		cookie_hashes[key] = true
	end
	local s_cookies = self.cookies
	local n = #s_cookies
	for index, value in pairs(s_cookies) do
		if cookie_hashes[value] then
			s_cookies[index] = nil
			local by_domain = s_cookies[value.domain]
			local by_path = by_domain[value.path]
			by_path[value.key] = nil
			if not next(by_path) then
				by_domain[value.path] = nil
				if not next(by_domain) then
					s_cookies[value.domain] = nil
				end
			end
		end
	end

	clear_holes(s_cookies, n)
end

function cookiejar_methods:remove_expired(time)
	self:remove_cookies(self:get_expired(time))
end

function cookiejar_methods:trim(size)
	self:remove_expired()
	local cookies = self.cookies
	if #cookies > size then
		for i=#cookies, size + 1, -1 do
			local cookie = cookies[i]
			cookies[i] = nil
			local by_domain = cookies[cookie.domain]
			local by_path = by_domain[cookie.path]
			by_path[cookie.key] = nil
			if not next(by_path) then
				by_domain[cookie.path] = nil
				if not next(by_domain) then
					cookies[cookie.domain] = nil
				end
			end
		end
	end
end

local function serialize_cookies(cookies)
	local out_values = {}
	for _, cookie in pairs(cookies) do
		out_values[#out_values + 1] = cookie.key .. "=" .. cookie.value
	end
	return table.concat(out_values, "; ")
end

function cookiejar_methods:serialize_cookies_for(domain, path, secure)
	-- explicitly check for secure; the other two will fail if given bad args
	assert(type(secure) == "boolean", "expected boolean for `secure`")

	-- clear out expired cookies
	self:remove_expired()

	-- return empty table if no cookies are found
	if not self.cookies[domain] then
		return {}
	end

	-- check all paths and flatten into a list of sets
	local sets = {}
	for stored_, set in pairs(self.cookies[domain]) do
		if stored_:sub(1, #path) == path then
			for _, cookie in pairs(set) do
				sets[#sets + 1] = cookie
			end
		end
	end

	-- sort as per RFC 6265 section 5.4 part 2; while it's not needed, it will
	-- help with tests where values need to be reproducible
	table.sort(sets, function(x, y)
		if #x.path == #y.path then
			return x.creation < y.creation
		else
			return #x.path > #y.path
		end
	end)

	-- populate cookie list
	local cookies = {}
	for _, cookie in pairs(sets) do
		if not cookie.host_only then
			if self.psl_object:is_cookie_domain_acceptable(domain, cookie.domain) then
				cookies[#cookies + 1] = cookie
			end
		elseif cookie.domain == domain then
			cookies[#cookies + 1] = cookie
		end
	end

	local n = #cookies
	-- remove cookies requiring secure connections on insecure connections
	for index, cookie in pairs(cookies) do
		if cookie.secure and not secure then
			cookies[index] = nil
		end
	end

	-- update access time for each cookie
	local time = os.time()
	for _, cookie in pairs(cookies) do
		cookie.last_access = time
	end

	clear_holes(cookies, n)
	return serialize_cookies(cookies)
end

return {
	iterate_cookies = iterate_cookies;
	parse_set_cookie = parse_set_cookie;
	bake_cookie = bake_cookie;
	parse_cookies = parse_cookies;
	serialize_cookies = serialize_cookies;
	cookiejar = {
		new = new_cookiejar;
		methods = cookiejar_methods;
		mt = cookiejar_mt;
	};
}
