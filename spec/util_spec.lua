describe("http.util module", function()
	local util = require "http.util"
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
