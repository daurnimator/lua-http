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
	local server = require "http.server"
	local util = require "http.util"
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
		local ws_client = websocket.new("client")
		ws_client.socket = c
		ws_client.readyState = 1
		local ws_server = websocket.new("server")
		ws_server.socket = s
		ws_server.readyState = 1
		return ws_client, ws_server
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
	for _, flag in ipairs{"RSV1", "RSV2", "RSV3"} do
		it("fails correctly on "..flag.." flag set", function()
			local cq = cqueues.new()
			local c, s = new_pair()
			cq:wrap(function()
				assert(c:send_frame({
					opcode = 1;
					[flag] = true;
				}))
				assert(c:close())
			end)
			cq:wrap(function()
				local ok, _, errno = s:receive()
				assert.same(nil, ok)
				assert.same(1002, errno)
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end
	it("ignores unsolicited pongs", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send_pong())
			assert(c:send("test"))
			assert(c:close())
		end)
		cq:wrap(function()
			assert.same("test", s:receive())
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("works when using uri string constructor", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			s:run(function (stream)
				local headers = assert(stream:get_headers())
				s:pause()
				local ws = websocket.new_from_stream(headers, stream)
				assert(ws:accept())
				assert(ws:close())
			end)
			s:close()
		end)
		cq:wrap(function()
			local ws = websocket.new_from_uri("ws://"..util.to_authority(host, port, "ws"));
			assert(ws:connect())
			assert(ws:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("works when using uri table constructor and protocols", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			s:run(function (stream)
				local headers = assert(stream:get_headers())
				s:pause()
				local ws = websocket.new_from_stream(headers, stream)
				assert(ws:accept({"my awesome-protocol", "foo"}))
				-- Should prefer client protocol preference
				assert.same("foo", ws.protocol)
				assert(ws:close())
			end)
			s:close()
		end)
		cq:wrap(function()
			local ws = websocket.new_from_uri_t({
				scheme = "ws";
				host = host;
				port = port;
			}, {"foo", "my-awesome-protocol", "bar"})
			assert(ws:connect())
			assert.same("foo", ws.protocol)
			assert(ws:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
