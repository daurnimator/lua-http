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

-- decodeURI unescapes url encoded characters
-- excluding for characters that are special in urls
local decodeURI do
	-- Keep the blacklist in numeric form.
	-- This means we can skip case normalisation of the hex characters
	local decodeURI_blacklist = {}
	for char in ("#$&+,/:;=?@"):gmatch(".") do
		decodeURI_blacklist[string.byte(char)] = true
	end
	local function decodeURI_helper(str)
		local x = tonumber(str, 16)
		if not decodeURI_blacklist[x] then
			return string.char(x)
		end
		-- return nothing; gsub will not perform the replacement
	end
	function decodeURI(str)
		return (str:gsub("%%(%x%x)", decodeURI_helper))
	end
end

-- Converts a hex string to a character
local function pchar_to_char(str)
	return string.char(tonumber(str, 16))
end

-- decodeURIComponent unescapes *all* url encoded characters
local function decodeURIComponent(str)
	return (str:gsub("%%(%x%x)", pchar_to_char))
end

-- An iterator over query segments (delimited by "&") as key/value pairs
-- if a query segment has no '=', the value will be `nil`
local function query_args(str)
	local iter, state, first = str:gmatch("([^=&]+)(=?)([^&]*)&?")
	return function(state, last) -- luacheck: ignore 431
		local name, equals, value = iter(state, last)
		if name == nil then return nil end
		name = decodeURIComponent(name)
		if equals == "" then
			value = nil
		else
			value = decodeURIComponent(value)
		end
		return name, value
	end, state, first
end

-- Converts a dictionary (string keys, string values) to an encoded query string
local function dict_to_query(form)
	local r, i = {}, 0
	for name, value in pairs(form) do
		i = i + 1
		r[i] = encodeURIComponent(name).."="..encodeURIComponent(value)
	end
	return table.concat(r, "&", 1, i)
end

local basexx = require "basexx"
local rand = require "openssl.rand"
local function generate_boundary()
	-- #bytes should have > 128 bits of entropy so collisions are improbable
	-- use characters in ASCII subset: base64 is something we already depend on.
	-- use a number of bytes divisible by 3 so base64 encoding doesn't waste bytes
	return basexx.to_url64(rand.bytes(18))
end

local auxlib = require "cqueues.auxlib"
local CHUNK_SIZE = 2^20 -- write in 1MB chunks
local function multipart_encode(boundary, parts)
	assert(boundary and parts, "missing argument")
	return auxlib.wrap(function()
		local first = true
		while true do
			local headers, body = parts()
			if headers == nil then
				break
			end

			local str, i = { first and "--" or "\r\n--", boundary, "\r\n" }, 3
			first = false
			for k, v in headers:each() do
				assert(type(k) == "string" and k:match("^[^:\r\n]+$"), "field name invalid")
				assert(type(v) == "string" and v:sub(-1, -1) ~= "\n" and not v:match("\n[^ ]"), "field value invalid")
				str[i+1] = k
				str[i+2] = ": "
				str[i+3] = v
				str[i+4] = "\r\n"
				i = i + 4
			end
			if i > 3 then
				str[i+1] = "\r\n"
				i = i + 1
			end
			coroutine.yield(table.concat(str, "", 1, i))

			if type(body) == "string" then
				coroutine.yield(body)
			elseif io.type(body) == "file" then
				assert(body:seek("set")) -- this implicity disallows non-seekable streams
				-- Can't use :lines here as in Lua 5.1 it doesn't take a parameter
				while true do
					local chunk, err = body:read(CHUNK_SIZE)
					if chunk == nil then
						if err then
							error(err)
						end
						break
					end
					coroutine.yield(chunk)
				end
			elseif type(body) == "function" then
				-- call function to get body segments
				while true do
					local chunk = body()
					if not chunk then
						break
					end
					coroutine.yield(chunk)
				end
			end
		end
		coroutine.yield("\r\n--"..boundary.."\r\n")
	end)
end

-- local function multipart_decode(boundary, stream, timeout)
-- 	local deadline = timeout and (monotime()+timeout)
-- 	local buffer = ""
-- 	while true do
-- 		local chunk, err, errno = stream:get_next_chunk(deadline and (deadline-monotime()))
-- 		if not chunk then
-- 			return nil, err, errno
-- 		end
-- 		buffer = buffer .. chunk
-- 		assert(buffer:sub(1, #boundary) == boundary)
-- 		-- read headers
-- 		-- search for boundary

-- 		local s, e = buffer:find(boundary, 1, true)
-- 		if s then
-- 			buffer

-- 			if buffer:sub(s-2, s-1) == "\r\n" then
-- 				s = s - 2
-- 			end
-- 			local data = buffer:sub(1, s-1)
-- 			buffer = buffer:sub(
-- 		end
-- 	end
-- end

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
	ws = 80;
	https = 443;
	wss = 443;
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
	decodeURI = decodeURI;
	decodeURIComponent = decodeURIComponent;
	query_args = query_args;
	dict_to_query = dict_to_query;
	generate_boundary = generate_boundary;
	multipart_encode = multipart_encode;
	resolve_relative_path = resolve_relative_path;
	scheme_to_port = scheme_to_port;
	split_authority = split_authority;
	to_authority = to_authority;
	split_header = split_header;
	imf_date = imf_date;
}
