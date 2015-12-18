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
		do -- with userinfo section
			local base64 = require "base64"
			local req = request.new_from_uri("https://user:password@example.com/")
			assert.same("example.com", req.host)
			assert.same(443, req.port)
			assert.truthy(req.tls)
			assert.same("example.com", req.headers:get ":authority")
			assert.same("GET", req.headers:get ":method")
			assert.same("/", req.headers:get ":path")
			assert.same("https", req.headers:get ":scheme")
			assert.same("user:password", base64.decode(req.headers:get "authorization":match "^basic%s+(.*)"))
			assert.same(nil, req.body)
		end
	end)
	it("fails on invalid URIs", function()
		assert.has.errors(function() request.new_from_uri("not a URI") end)

		-- no scheme
		assert.has.errors(function() request.new_from_uri("example.com") end)
	end)
	it("can (sometimes) roundtrip via :to_url()", function()
		local function test(uri)
			local req = request.new_from_uri(uri)
			assert.same(uri, req:to_url())
		end
		test("http://example.com/")
		test("https://example.com/")
		test("https://example.com:1234/")
	end)
	it("handles CONNECT requests in :to_url()", function()
		local function test(uri)
			local req = request.new_connect(uri, "connect.me")
			assert.same(uri, req:to_url())
		end
		test("http://example.com")
		test("https://example.com")
		test("https://example.com:1234")
		assert.has.errors(function() test("https://example.com/path") end)
	end)
	it(":handle_redirect works", function()
		local headers = require "http.headers"
		do
			local orig_req = request.new_from_uri("http://example.com")
			local orig_headers = headers.new()
			orig_headers:append(":status", "301")
			orig_headers:append("location", "/foo")
			local new_req = orig_req:handle_redirect(orig_headers)
			-- same
			assert.same(orig_req.host, new_req.host)
			assert.same(orig_req.port, new_req.port)
			assert.same(orig_req.tls, new_req.tls)
			assert.same(orig_req.headers:get ":authority", new_req.headers:get ":authority")
			assert.same(orig_req.headers:get ":method", new_req.headers:get ":method")
			assert.same(orig_req.headers:get ":scheme", new_req.headers:get ":scheme")
			assert.same(orig_req.body, new_req.body)
			-- different
			assert.same("/foo", new_req.headers:get ":path")
			assert.same(orig_req.max_redirects-1, new_req.max_redirects)
		end
		do
			local orig_req = request.new_from_uri("http://example.com")
			local orig_headers = headers.new()
			orig_headers:append(":status", "302")
			orig_headers:append("location", "//blah.com:1234/example")
			local new_req = orig_req:handle_redirect(orig_headers)
			-- same
			assert.same(orig_req.tls, new_req.tls)
			assert.same(orig_req.headers:get ":method", new_req.headers:get ":method")
			assert.same(orig_req.headers:get ":scheme", new_req.headers:get ":scheme")
			assert.same(orig_req.body, new_req.body)
			-- different
			assert.same("blah.com", new_req.host)
			assert.same(1234, new_req.port)
			assert.same("blah.com:1234", new_req.headers:get ":authority")
			assert.same("/example", new_req.headers:get ":path")
			assert.same(orig_req.max_redirects-1, new_req.max_redirects)
		end
		do -- maximum redirects exceeded
			local ce = require "cqueues.errno"
			local orig_req = request.new_from_uri("http://example.com")
			orig_req.max_redirects = 0
			local orig_headers = headers.new()
			orig_headers:append(":status", "302")
			orig_headers:append("location", "/")
			assert.same({nil, "maximum redirects exceeded", ce.ELOOP}, {orig_req:handle_redirect(orig_headers)})
		end
		do -- missing location header
			local ce = require "cqueues.errno"
			local orig_req = request.new_from_uri("http://example.com")
			local orig_headers = headers.new()
			orig_headers:append(":status", "302")
			assert.same({nil, "missing location header for redirect", ce.EINVAL}, {orig_req:handle_redirect(orig_headers)})
		end
	end)
end)
