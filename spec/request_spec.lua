describe("http.request module", function()
	local request = require "http.request"
	it("can construct a request from a uri", function()
		do -- http url; no path
			local req = request.new_from_uri("http://example.com")
			assert.same("example.com", req.host)
			assert.same(80, req.port)
			assert.falsy(req.tls)
			assert.same("example.com", req.headers:get ":authority")
			assert.same("GET", req.headers:get ":method")
			assert.same("/", req.headers:get ":path")
			assert.same("http", req.headers:get ":scheme")
			assert.same(nil, req.body)
		end
		do -- https
			local req = request.new_from_uri("https://example.com/path?query")
			assert.same("example.com", req.host)
			assert.same(443, req.port)
			assert.truthy(req.tls)
			assert.same("example.com", req.headers:get ":authority")
			assert.same("GET", req.headers:get ":method")
			assert.same("/path?query", req.headers:get ":path")
			assert.same("https", req.headers:get ":scheme")
			assert.same(nil, req.body)
		end
	end)
	it("fails on invalid URIs", function()
		assert.has.errors(function() request.new_from_uri("not a URI") end)

		-- no scheme
		assert.has.errors(function() request.new_from_uri("example.com") end)
	end)
end)
