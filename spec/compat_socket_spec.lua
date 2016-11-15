describe("http.compat.socket module", function()
	local http = require "http.compat.socket"
	local new_headers = require "http.headers".new
	local server = require "http.server"
	local util = require "http.util"
	local cqueues = require "cqueues"
	it("fails safely on an invalid host", function()
		-- in the luasocket example they use 'wrong.host', but 'host' is now a valid TLD.
		-- use 'wrong.invalid' instead for this test.
		local r, e = http.request("http://wrong.invalid/")
		assert.same(r, nil)
		-- in luasocket, the error is documented as "host not found", but we allow something else
		assert.same("string", type(e))
	end)
	it("works against builtin server with GET request", function()
		local cq = cqueues.new()
		local authority
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local request_headers = assert(stream:get_headers())
				assert.same("http", request_headers:get ":scheme")
				assert.same("GET", request_headers:get ":method")
				assert.same("/foo", request_headers:get ":path")
				assert.same(authority, request_headers:get ":authority")
				local headers = new_headers()
				headers:append(":status", "200")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("hello world", true))
				s:close()
			end;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		authority = util.to_authority(host, port, "http")
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local r, e = http.request("http://"..authority.."/foo")
			assert.same("hello world", r)
			assert.same(200, e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("works against builtin server with POST request", function()
		local cq = cqueues.new()
		local authority
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local request_headers = assert(stream:get_headers())
				assert.same("http", request_headers:get ":scheme")
				assert.same("POST", request_headers:get ":method")
				assert.same("/foo", request_headers:get ":path")
				assert.same(authority, request_headers:get ":authority")
				local body = assert(stream:get_body_as_string())
				assert.same("a body", body)
				local headers = new_headers()
				headers:append(":status", "201")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("hello world", true))
				s:close()
			end;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		authority = util.to_authority(host, port, "http")
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local r, e = http.request("http://"..authority.."/foo", "a body")
			assert.same("hello world", r)
			assert.same(201, e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("works against builtin server with complex request", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local a, b = stream:get_headers()
				local request_headers = assert(a,b)
				assert.same("http", request_headers:get ":scheme")
				assert.same("PUT", request_headers:get ":method")
				assert.same("/path?query", request_headers:get ":path")
				assert.same("otherhost.com:8080", request_headers:get ":authority")
				assert.same("fun", request_headers:get "myheader")
				assert.same("normalised", request_headers:get "camelcase")
				assert(stream:write_continue())
				local body = assert(stream:get_body_as_string())
				assert.same("a body", body)
				local headers = new_headers()
				headers:append(":status", "404")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("hello world", true))
				s:close()
			end;
		}
		assert(s:listen())
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local _, host, port = s:localname()
			local r, e = assert(http.request {
				url = "http://example.com/path?query";
				host = host;
				port = port;
				method = "PUT";
				headers = {
					host = "otherhost.com:8080";
					myheader = "fun";
					CamelCase = "normalised";
				};
				source = coroutine.wrap(function()
					coroutine.yield("a body")
				end);
				sink = coroutine.wrap(function(b)
					assert.same("hello world", b)
					assert.same(nil, coroutine.yield(true))
				end);
			})
			assert.same(1, r)
			assert.same(404, e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("returns nil, 'timeout' on timeout", function()
		local cq = cqueues.new()
		local authority
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				assert(stream:get_headers())
				cqueues.sleep(0.2)
				stream:shutdown()
				s:close()
			end;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		authority = util.to_authority(host, port, "http")
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local old_TIMEOUT = http.TIMEOUT
			http.TIMEOUT = 0.01
			local r, e = http.request("http://"..authority.."/")
			http.TIMEOUT = old_TIMEOUT
			assert.same(nil, r)
			assert.same("timeout", e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("handles timeouts in complex form", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local a, b = stream:get_headers()
				local request_headers = assert(a,b)
				assert.same("http", request_headers:get ":scheme")
				assert.same("GET", request_headers:get ":method")
				assert.same("/path?query", request_headers:get ":path")
				assert.same("example.com", request_headers:get ":authority")
				cqueues.sleep(0.2)
				s:close()
			end;
		}
		assert(s:listen())
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local _, host, port = s:localname()
			local old_TIMEOUT = http.TIMEOUT
			http.TIMEOUT = 0.01
			local r, e = http.request {
				url = "http://example.com/path?query";
				host = host;
				port = port;
			}
			http.TIMEOUT = old_TIMEOUT
			assert.same(nil, r)
			assert.same("timeout", e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("coerces numeric header values to strings", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local request_headers = assert(stream:get_headers())
				assert.truthy(request_headers:has("myheader"))
				local headers = new_headers()
				headers:append(":status", "200")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, true))
				s:close()
			end;
		}
		assert(s:listen())
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local _, host, port = s:localname()
			local r, e = assert(http.request {
				url = "http://anything/";
				host = host;
				port = port;
				headers = {
					myheader = 2;
				};
			})
			assert.same(1, r)
			assert.same(200, e)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
