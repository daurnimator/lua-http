local TEST_TIMEOUT = 2
describe("http.compat.prosody module", function()
	local cqueues = require "cqueues"
	local request = require "http.compat.prosody".request
	local new_headers = require "http.headers".new
	local server = require "http.server"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
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
	it("can perform a GET request", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			s:run(function(stream)
				local h = assert(stream:get_headers())
				assert.same("http", h:get ":scheme")
				assert.same("GET", h:get ":method")
				assert.same("/", h:get ":path")
				local headers = new_headers()
				headers:append(":status", "200")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("success!", true))
				stream:shutdown()
				stream.connection:shutdown()
			end)
			s:close()
		end)
		cq:wrap(function()
			request(string.format("http://%s:%d", host, port), {}, function(b, c)
				assert.same(200, c)
				assert.same("success!", b)
				s:pause()
			end)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("can perform a POST request", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			s:run(function(stream)
				local h = assert(stream:get_headers())
				assert.same("http", h:get ":scheme")
				assert.same("POST", h:get ":method")
				assert.same("/path", h:get ":path")
				assert.same("text/plain", h:get "content-type")
				local b = assert(stream:get_body_as_string())
				assert.same("this is a body", b)
				local headers = new_headers()
				headers:append(":status", "201")
				headers:append("connection", "close")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk("success!", true))
				stream:shutdown()
				stream.connection:shutdown()
			end)
			s:close()
		end)
		cq:wrap(function()
			request(string.format("http://%s:%d/path", host, port), {
					headers = {
						["content-type"] = "text/plain";
					};
					body = "this is a body";
				}, function(b, c)
				assert.same(201, c)
				assert.same("success!", b)
				s:pause()
			end)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
