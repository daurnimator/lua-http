local TEST_TIMEOUT = 2
describe("http.compat.socket module", function()
	local http = require "http.compat.socket"
	local new_headers = require "http.headers".new
	local server = require "http.server"
	local util = require "http.util"
	local cqueues = require "cqueues"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
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
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		local authority = util.to_authority(host, port, "http")
		cq:wrap(function()
			s:run(function (stream)
				local request_headers = assert(stream:get_headers())
				s:pause()
				assert.same("http", request_headers:get ":scheme")
				assert.same("GET", request_headers:get ":method")
				assert.same("/foo", request_headers:get ":path")
				assert.same(authority, request_headers:get ":authority")
				local headers = new_headers()
				headers:append(":status", "200")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("hello world", true))
			end)
			s:close()
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
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		local authority = util.to_authority(host, port, "http")
		cq:wrap(function()
			s:run(function (stream)
				s:pause()
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
			end)
			s:close()
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
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			s:run(function (stream)
				s:pause()
				local request_headers = assert(stream:get_headers())
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
			end)
			s:close()
		end)
		cq:wrap(function()
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
end)
