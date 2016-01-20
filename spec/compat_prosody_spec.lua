describe("http.compat.prosody module", function()
	local cqueues = require "cqueues"
	local request = require "http.compat.prosody".request
	it("invalid uris fail", function()
		local s = spy.new(function() end)
		assert(cqueues.new():wrap(function()
			assert.same({nil, "invalid-url"}, {request("this is not a url", {}, s)})
		end):loop())
		assert.spy(s).was.called()
	end)
	it("can construct a request from a uri", function()
		-- Only step; not loop. use `error` as callback as it should never be called
		assert(cqueues.new():wrap(function()
			assert(request("http://example.com", {}, error))
		end):step())
		assert(cqueues.new():wrap(function()
			local r = assert(request("http://example.com/something", {
				method = "PUT";
				body = '{}';
				headers = {
					["content-type"] = "application/json";
				}
			}, error))
			assert.same("PUT", r.headers:get(":method"))
			assert.same("application/json", r.headers:get("content-type"))
			assert.same("2", r.headers:get("content-length"))
			assert.same("{}", r.body)
		end):step())
	end)
end)
