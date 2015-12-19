local TEST_TIMEOUT = 2
describe("server module", function()
	local server = require "http.server"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	it("works", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "127.0.0.1";
			port = 8000;
		}
		s:listen()
		local on_stream = spy.new(function(stream)
			stream:get_headers()
			stream:shutdown()
			s:shutdown()
		end)
		cq:wrap(function()
			s:run(on_stream)
			s:close()
		end)
		cq:wrap(function()
			local c = assert(cs.connect{
				host = "127.0.0.1";
				port = 8000;
			})
			assert(c:connect())
			c:setmode("b", "nb")
			assert(c:write("GET / HTTP/1.0\r\n\r\n", "n"))
			c:read()
			c:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.spy(on_stream).was.called()
	end)
end)
