--[[
Data structures useful for HSTS (HTTP Strict Transport Security)
HSTS is described in RFC 6797
]]

local http_util = require "http.util"

local store_methods = {
	time = function() return os.time() end;
}

local store_mt = {
	__name = "http.hsts.store";
	__index = store_methods;
}

local store_item_methods = {}
local store_item_mt = {
	__name = "http.hsts.store_item";
	__index = store_item_methods;
}

local function new_store()
	return setmetatable({
		domains = {};
	}, store_mt)
end

function store_methods:clone()
	local r = new_store()
	r.time = rawget(self, "time")
	for host, item in pairs(self.domains) do
		r.domains[host] = item
	end
	return r
end

function store_methods:store(host, directives)
	local now = self.time()
	local max_age = directives["max-age"]
	if max_age == nil then
		return nil, "max-age directive is required"
	elseif type(max_age) ~= "string" or max_age:match("[^0-9]") then
		return nil, "max-age directive does not match grammar"
	else
		max_age = tonumber(max_age, 10)
	end
	if http_util.is_ip(host) then
		return false
	end
	if max_age == 0 then
		-- delete from store
		self.domains[host] = nil
	else
		-- add to store
		self.domains[host] = setmetatable({
			includeSubdomains = directives.includeSubdomains;
			expires = now + max_age;
		}, store_item_mt)
	end
	return true
end

function store_methods:check(host)
	if http_util.is_ip(host) then
		return false
	end
	local now = self.time()
	local h = host
	repeat
		local item = self.domains[h]
		if item then
			if item.expires < now then
				self:clean()
			elseif host == h or item.includeSubdomains then
				return true
			end
		end
		local n
		h, n = h:gsub("^[^%.]+%.", "", 1)
	until n == 0
	return false
end

function store_methods:clean()
	local now = self.time()
	for host, item in pairs(self.domains) do
		if item.expires < now then
			self.domains[host] = nil
		end
	end
	return true
end

return {
	new_store = new_store;
	store_mt = store_mt;
	store_methods = store_methods;
}
