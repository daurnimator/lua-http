describe("http.util module", function()
	local unpack = table.unpack or unpack -- luacheck: ignore 113
	local util = require "http.util"
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
	it("split_header works correctly", function()
		-- nil
		assert.same({n=0}, util.split_header(nil))
		-- empty string
		assert.same({n=0}, util.split_header(""))
		assert.same({n=1,"foo"}, util.split_header("foo"))
		-- whitespace before and/or after
		assert.same({n=1,"foo"}, util.split_header("foo  "))
		assert.same({n=1,"foo"}, util.split_header("  foo"))
		assert.same({n=1,"foo"}, util.split_header("  foo  "))
		-- trailing comma
		assert.same({n=1,"foo"}, util.split_header("foo,"))
		assert.same({n=1,"foo"}, util.split_header("foo  ,"))
		-- leading comma
		assert.same({n=1,"foo"}, util.split_header(",foo"))
		assert.same({n=1,"foo"}, util.split_header(",foo  "))
		assert.same({n=1,"foo"}, util.split_header("  ,foo"))
		assert.same({n=1,"foo"}, util.split_header("  ,  foo"))
		-- two items
		assert.same({n=2,"foo", "bar"}, util.split_header("foo,bar"))
		assert.same({n=2,"foo", "bar"}, util.split_header("foo, bar"))
		assert.same({n=2,"foo", "bar"}, util.split_header("foo,  bar"))
		assert.same({n=2,"foo", "bar"}, util.split_header("foo,  bar"))
		-- more items
		assert.same({n=3,"foo", "bar", "qux"}, util.split_header("foo,  bar,qux"))
		assert.same({n=5,"foo", "bar", "qux", "more q=123","thing"},
			util.split_header(",foo,  bar,qux , more q=123,thing  "))
	end)
	it("generates correct looking Date header format", function()
		assert.same("Fri, 13 Feb 2009 23:31:30 GMT", util.imf_date(1234567890))
	end)
end)
