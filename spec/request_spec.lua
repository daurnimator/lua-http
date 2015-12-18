describe("http.request module", function()
	local request = require "http.request"
	it("fails on invalid URIs", function()
		assert.has.errors(function() request.new_from_uri("not a URI") end)

		-- no scheme
		assert.has.errors(function() request.new_from_uri("example.com") end)
	end)
end)
