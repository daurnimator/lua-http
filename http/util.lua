-- Many HTTP headers contain comma seperated values
-- This function returns an iterator over header components
local function each_header_component(str)
	return str:gmatch(" *([^ ,][^,]-) *%f[,%z]")
end

local function split_header(str)
	if str == nil then
		return { n = 0 }
	end
	local r, n = { n = nil }, 0
	for elem in each_header_component(str) do
		n = n + 1
		r[n] = elem
	end
	r.n = n
	return r
end

return {
	split_header = split_header;
}
