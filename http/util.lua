-- Encodes a character as a percent encoded string
local function char_to_pchar(c)
	return string.format("%%%02X", c:byte(1,1))
end

-- encodeURI replaces all characters except the following with the appropriate UTF-8 escape sequences:
-- ; , / ? : @ & = + $
-- alphabetic, decimal digits, - _ . ! ~ * ' ( )
-- #
local function encodeURI(str)
	return (str:gsub("[^%;%,%/%?%:%@%&%=%+%$%w%-%_%.%!%~%*%'%(%)%#]", char_to_pchar))
end

-- encodeURIComponent escapes all characters except the following: alphabetic, decimal digits, - _ . ! ~ * ' ( )
local function encodeURIComponent(str)
	return (str:gsub("[^%w%-_%.%!%~%*%'%(%)]", char_to_pchar))
end

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

local scheme_to_port = {
	http = 80;
	https = 443;
}

-- Splits a :authority header (same as Host) into host and port
local function split_authority(authority, scheme)
	local host, port
	local h, p = authority:match("^ *(.-):(%d+) *$")
	if p then
		authority = h
		port = tonumber(p)
	else -- when port missing from host header, it defaults to the default for that scheme
		port = scheme_to_port[scheme]
		if port == nil then
			error("unknown scheme")
		end
	end
	local ipv6 = authority:match("%[([:%x]+)%]")
	if ipv6 then
		host = ipv6
	else
		host = authority
	end
	return host, port
end

-- Reverse of `split_authority`: converts a host, port and scheme
-- into a string suitable for an :authority header.
local function to_authority(host, port, scheme)
	local authority = host
	if host:match("^[%x:]+:[%x:]*$") then -- IPv6
		authority = "[" .. authority .. "]"
	end
	local default_port = scheme_to_port[scheme]
	if default_port == port then
		port = nil
	end
	if port then
		authority = string.format("%s:%d", authority, port)
	end
	return authority
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

-- HTTP prefered date format
-- See RFC 7231 section 7.1.1.1
local function imf_date(time)
	return os.date("!%a, %d %b %Y %H:%M:%S GMT", time)
end

return {
	encodeURI = encodeURI;
	encodeURIComponent = encodeURIComponent;
	resolve_relative_path = resolve_relative_path;
	scheme_to_port = scheme_to_port;
	split_authority = split_authority;
	to_authority = to_authority;
	split_header = split_header;
	imf_date = imf_date;
}
