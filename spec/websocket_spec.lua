local TEST_TIMEOUT = 2
describe("http.websocket module's internal functions work", function()
	local websocket = require "http.websocket"
	it("build_frame works for simple cases", function()
		-- Examples from RFC 6455 Section 5.7

		-- A single-frame unmasked text message
		assert.same(string.char(0x81,0x05,0x48,0x65,0x6c,0x6c,0x6f), websocket.build_frame {
			FIN = true;
			MASK = false;
			opcode = 0x1;
			data = "Hello";
		})

		-- A single-frame masked text message
		assert.same(string.char(0x81,0x85,0x37,0xfa,0x21,0x3d,0x7f,0x9f,0x4d,0x51,0x58), websocket.build_frame {
			FIN = true;
			MASK = true;
			key = {0x37,0xfa,0x21,0x3d};
			opcode = 0x1;
			data = "Hello";
		})
	end)
	it("build_frame validates opcode", function()
		assert.has.errors(function()
			websocket.build_frame { opcode = -1; }
		end)
		assert.has.errors(function()
			websocket.build_frame { opcode = 16; }
		end)
	end)
	it("build_frame validates data length", function()
		assert.has.errors(function()
			websocket.build_frame {
				opcode = 0x8;
				data = ("f"):rep(200);
			}
		end)
	end)
	it("build_close works for common case", function()
		assert.same({
			opcode = 0x8;
			FIN = true;
			MASK = false;
			data = "\3\232";
		}, websocket.build_close(1000, nil, false))

		assert.same({
			opcode = 0x8;
			FIN = true;
			MASK = false;
			data = "\3\232error";
		}, websocket.build_close(1000, "error", false))
	end)
	it("build_close validates string length", function()
		assert.has.errors(function() websocket.build_close(1000, ("f"):rep(200), false) end)
	end)
	it("parse_close works", function()
		assert.same({nil, nil}, {websocket.parse_close ""})
		assert.same({1000, nil}, {websocket.parse_close "\3\232"})
		assert.same({1000, "error"}, {websocket.parse_close "\3\232error"})
	end)
end)
describe("http.websocket module two sided tests", function()
	local websocket = require "http.websocket"
	local cs = require "cqueues.socket"
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
	local function new_pair()
		local c, s = cs.pair()
		local client = websocket.new("client")
		client.socket = c
		client.readyState = 1
		local server = websocket.new("server")
		server.socket = s
		server.readyState = 1
		return client, server
	end
	it("works with a socketpair", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send("hello"))
			assert.same("world", c:receive())
			assert(c:close())
		end)
		cq:wrap(function()
			assert.same("hello", s:receive())
			assert(s:send("world"))
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
