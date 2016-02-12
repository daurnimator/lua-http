local TEST_TIMEOUT = 2
describe("http.server module", function()
	local server = require "http.server"
	local client = require "http.client"
	local new_headers = require "http.headers".new
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
	local function simple_test(tls, version)
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		local on_stream = spy.new(function(stream)
			stream:get_headers()
			stream:shutdown()
			s:pause()
		end)
		cq:wrap(function()
			s:run(on_stream)
			s:close()
		end)
		cq:wrap(function()
			local conn = client.connect {
				host = host;
				port = port;
				tls = tls;
				version = version;
			}
			local stream = conn:new_stream()
			local headers = new_headers()
			headers:append(":method", "GET")
			headers:append(":path", "/")
			headers:append(":scheme", "http")
			assert(stream:write_headers(headers, true))
			stream:get_headers()
			conn:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.spy(on_stream).was.called()
	end
	it("works with plain http 1.1", function()
		simple_test(false, 1.1)
	end)
	it("works with https 1.1", function()
		simple_test(true, 1.1)
	end)
	it("works with plain http 2.0", function()
		simple_test(false, 2.0)
	end);
	(require "http.tls".has_alpn and it or pending)("works with https 2.0", function()
		simple_test(true, 2.0)
	end)
end)
