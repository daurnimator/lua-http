-- Resolves a relative path
local function resolve_relative_path(orig_path, relative_path)
	local t, i = {}, 0

	local is_abs
	if relative_path:sub(1,1) == "/" then
		-- "relative" argument is actually absolute. ignore orig_path argument
		is_abs = true
	else
		is_abs = orig_path:sub(1,1) == "/"
		-- this will skip empty path components due to +
		-- the / on the end ignores trailing component
		for segment in orig_path:gmatch("([^/]+)/") do
			i = i + 1
			t[i] = segment
		end
	end

	for segment in relative_path:gmatch("([^/]+)") do
		if segment == ".." then
			-- if we're at the root, do nothing
			if i > 0 then
				-- discard a component
				i = i - 1
			end
		elseif segment ~= "." then
			i = i + 1
			t[i] = segment
		end
	end

	-- Make sure leading slash is kept
	local s
	if is_abs then
		if i == 0 then return "/" end
		t[0] = ""
		s = 0
	else
		s = 1
	end
	-- Make sure trailing slash is kept
	if relative_path:sub(-1, -1) == "/" then
		i = i + 1
		t[i] = ""
	end
	return table.concat(t, "/", s, i)
end

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
	resolve_relative_path = resolve_relative_path;
	split_header = split_header;
}
