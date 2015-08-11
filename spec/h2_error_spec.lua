describe("", function()
	local h2_error = require "http.h2_error"
	it("has the registered errors", function()
		for i=0, 0xd do
			-- indexed by code
			assert.same(i, h2_error.errors[i].code)
			-- and indexed by name
			assert.same(h2_error.errors[i], h2_error.errors[h2_error.errors[i].name])
		end
	end)
	it("has a nice tostring", function()
		local e = h2_error.errors[0]:new{
			message = "oops";
			traceback = "some traceback";
		}
		assert.same("NO_ERROR(0x0): Graceful shutdown: oops\nsome traceback", tostring(e))
	end)
	it("`is` function works", function()
		assert.truthy(h2_error.is(h2_error.errors[0]))
		assert.falsy(h2_error.is({}))
		assert.falsy(h2_error.is("string"))
		assert.falsy(h2_error.is(1))
		assert.falsy(h2_error.is(coroutine.create(function()end)))
		assert.falsy(h2_error.is(io.stdin))
	end)
	it("throws errors when called", function()
		assert.has.errors(function() h2_error.errors[0]("oops", 0) end, {
			name = "NO_ERROR";
			code = 0;
			description = "Graceful shutdown";
			message = "oops";
		})
	end)
	it("adds a traceback field", function()
		local ok, err = pcall(h2_error.errors[0])
		assert.falsy(ok)
		assert.truthy(err.traceback)
	end)
	it(":assert works", function()
		assert.falsy(pcall(h2_error.errors[0].assert, h2_error.errors[0], false))
		assert.truthy(pcall(h2_error.errors[0].assert, h2_error.errors[0], true))
	end)
	it(":assert adds a traceback field", function()
		local ok, err = pcall(h2_error.errors[0].assert, h2_error.errors[0], false)
		assert.falsy(ok)
		assert.truthy(err.traceback)
	end)
end)
