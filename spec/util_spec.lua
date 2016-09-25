describe("http.util module", function()
	local unpack = table.unpack or unpack -- luacheck: ignore 113
	local util = require "http.util"
	it("decodeURI works", function()
		assert.same("Encoded string", util.decodeURI("Encoded%20string"))
	end)
	it("decodeURI doesn't decode blacklisted characters", function()
		assert.same("%24", util.decodeURI("%24"))
		local s = util.encodeURIComponent("#$&+,/:;=?@")
		assert.same(s, util.decodeURI(s))
	end)
	it("decodeURIComponent round-trips with encodeURIComponent", function()
		local allchars do
			local t = {}
			for i=0, 255 do
				t[i] = i
			end
			allchars = string.char(unpack(t, 0, 255))
		end
		assert.same(allchars, util.decodeURIComponent(util.encodeURIComponent(allchars)))
	end)
	it("query_args works", function()
		do
			local iter, state, first = util.query_args("foo=bar")
			assert.same({"foo", "bar"}, {iter(state, first)})
			assert.same(nil, iter(state, first))
		end
		do
			local iter, state, first = util.query_args("foo=bar&baz=qux&foo=somethingelse")
			assert.same({"foo", "bar"}, {iter(state, first)})
			assert.same({"baz", "qux"}, {iter(state, first)})
			assert.same({"foo", "somethingelse"}, {iter(state, first)})
			assert.same(nil, iter(state, first))
		end
		do
			local iter, state, first = util.query_args("%3D=%26")
			assert.same({"=", "&"}, {iter(state, first)})
			assert.same(nil, iter(state, first))
		end
		do
			local iter, state, first = util.query_args("foo=bar&noequals")
			assert.same({"foo", "bar"}, {iter(state, first)})
			assert.same({"noequals", nil}, {iter(state, first)})
			assert.same(nil, iter(state, first))
		end
	end)
	it("dict_to_query works", function()
		assert.same("foo=bar", util.dict_to_query{foo = "bar"})
		assert.same("foo=%CE%BB", util.dict_to_query{foo = "λ"})
		do
			local t = {foo = "bar"; baz = "qux"}
			local r = {}
			for k, v in util.query_args(util.dict_to_query(t)) do
				r[k] = v
			end
			assert.same(t, r)
		end
	end)
	it("split_authority works", function()
		assert.same({"example.com", 80}, {util.split_authority("example.com", "http")})
		assert.same({"example.com", 8000}, {util.split_authority("example.com:8000", "http")})
		assert.has.errors(function()
			util.split_authority("example.com", "madeupscheme")
		end)
		-- IPv6
		assert.same({"::1", 443}, {util.split_authority("[::1]", "https")})
		assert.same({"::1", 8000}, {util.split_authority("[::1]:8000", "https")})
	end)
	it("to_authority works", function()
		assert.same("example.com", util.to_authority("example.com", 80, "http"))
		assert.same("example.com:8000", util.to_authority("example.com", 8000, "http"))
		-- IPv6
		assert.same("[::1]", util.to_authority("::1", 443, "https"))
		assert.same("[::1]:8000", util.to_authority("::1", 8000, "https"))
	end)
	it("generates correct looking Date header format", function()
		assert.same("Fri, 13 Feb 2009 23:31:30 GMT", util.imf_date(1234567890))
	end)
	describe("maybe_quote", function()
		it("makes acceptable tokens or quoted-string", function()
			assert.same([[foo]], util.maybe_quote([[foo]]))
			assert.same([["with \" quote"]], util.maybe_quote([[with " quote]]))
		end)
		it("escapes all bytes correctly", function()
			local http_patts = require "lpeg_patterns.http"
			local s do -- Make a string containing every byte allowed in a quoted string
				local t = {"\t"} -- tab
				for i=32, 126 do
					t[#t+1] = string.char(i)
				end
				for i=128, 255 do
					t[#t+1] = string.char(i)
				end
				s = table.concat(t)
			end
			assert.same(s, http_patts.quoted_string:match(util.maybe_quote(s)))
		end)
		it("returns nil on invalid input", function()
			local function check(s)
				assert.same(nil, util.maybe_quote(s))
			end
			for i=0, 8 do
				check(string.char(i))
			end
			-- skip tab
			for i=10, 31 do
				check(string.char(i))
			end
			check("\127")
		end)
	end)
end)
