--[[
HTTP Header data structure/type

Design criteria:
  - the same header field is allowed more than once
      - must be able to fetch seperate occurences (important for some headers e.g. Set-Cookie)
      - optionally available as comma seperated list
  - http2 adds flag to headers that they should never be indexed
  - header order should be recoverable

I chose to implement headers as an array of entries.
An index of field name => array indices is kept.
]]

local unpack = table.unpack or unpack

local entry_methods = {}
local entry_mt = {
	__index = entry_methods;
}

local function new_entry(name, value, never_index)
	return setmetatable({
		name = name;
		value = value;
		never_index = never_index;
	}, entry_mt)
end

function entry_methods:modify(value, never_index)
	self.value = value
	self.never_index = never_index
end

function entry_methods:unpack()
	return self.name, self.value, self.never_index
end


local headers_methods = {}
local headers_mt = {
	__index = headers_methods;
}

local function new_headers()
	return setmetatable({
		n = 0;
		_index = {}
	}, headers_mt)
end

local function add_to_index(_index, name, i)
	local dex = _index[name]
	if dex == nil then
		dex = {i}
		_index[name] = dex
	else
		table.insert(dex, i)
	end
end

local function rebuild_index(self)
	local index = {}
	for i=1, self.n do
		local entry = self[i]
		add_to_index(index, entry.name, i)
	end
	self._index = index
end

function headers_methods:append(name, ...)
	local n = self.n + 1
	self[n] = new_entry(name, ...)
	add_to_index(self._index, name, n)
	self.n = n
end

function headers_methods:each()
	local i = 0
	return function(self) -- luacheck: ignore 432
		if i >= self.n then return end
		i = i + 1
		local entry = self[i]
		return entry:unpack()
	end, self
end

function headers_methods:has(name)
	local dex = self._index[name]
	return dex ~= nil
end

function headers_methods:get(name)
	local dex = self._index[name]
	if dex == nil then return nil end
	local r = {}
	local n = #dex
	for i=1, n do
		r[i] = self[dex[i]].value
	end
	return unpack(r, 1, n)
end

function headers_methods:upsert(name, ...)
	local dex = self._index[name]
	if dex == nil then
		self:append(name, ...)
	else
		assert(dex[2] == nil, "Cannot upsert multi-valued field")
		self[dex[1]]:modify(...)
	end
end

return {
	new = new_headers;
	methods = headers_methods;
	mt = headers_mt;
}
