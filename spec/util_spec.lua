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
