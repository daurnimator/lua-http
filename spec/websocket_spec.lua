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
	it("build_close can generate frames without a code", function()
		assert.same({
			opcode = 0x8;
			FIN = true;
			MASK = false;
			data = "";
		}, websocket.build_close(nil, nil, false))
	end)
	it("parse_close works", function()
		assert.same({nil, nil}, {websocket.parse_close ""})
		assert.same({1000, nil}, {websocket.parse_close "\3\232"})
		assert.same({1000, "error"}, {websocket.parse_close "\3\232error"})
	end)
end)
describe("http.websocket", function()
	local websocket = require "http.websocket"
	it("__tostring works", function()
		local ws = websocket.new_from_uri("wss://example.com")
		assert.same("http.websocket{", tostring(ws):match("^.-%{"))
	end)
	it("close on a new websocket doesn't throw an error", function()
		local ws = websocket.new_from_uri("wss://example.com")
		ws:close() -- this shouldn't throw
	end)
	describe("new_from_stream", function()
		local ca = require "cqueues.auxlib"
		local cs = require "cqueues.socket"
		local ce = require "cqueues.errno"
		local h1_connection = require "http.h1_connection"
		local http_headers = require "http.headers"
		local function new_connection_pair(version)
			local s, c = ca.assert(cs.pair())
			s = h1_connection.new(s, "server", version)
			c = h1_connection.new(c, "client", version)
			return s, c
		end
		local correct_headers = http_headers.new()
		correct_headers:append(":method", "GET")
		correct_headers:append(":scheme", "http")
		correct_headers:append(":authority", "example.com")
		correct_headers:append(":path", "/")
		correct_headers:append("upgrade", "websocket")
		correct_headers:append("connection", "upgrade")
		correct_headers:append("sec-websocket-key", "foo", true)
		correct_headers:append("sec-websocket-version", "13")
		it("works with correct parameters", function()
			local s, c = new_connection_pair(1.1)
			local c_stream = c:new_stream()
			c_stream:write_headers(correct_headers, false)
			local s_stream = assert(s:get_next_incoming_stream(TEST_TIMEOUT))
			local s_headers = assert(s_stream:get_headers(TEST_TIMEOUT))
			local ws = assert(websocket.new_from_stream(s_stream, s_headers))
			s:close()
			ws:close()
		end)
		it("rejects client streams", function()
			local s, c = new_connection_pair(1.1)
			local c_stream = c:new_stream()
			assert.has.errors(function() websocket.new_from_stream(c_stream, correct_headers) end)
			s:close()
			c:close()
		end)
		it("rejects non-1.0 connections", function()
			local s, c = new_connection_pair(1.0)
			local c_stream = c:new_stream()
			c_stream:write_headers(correct_headers, false)
			local s_stream = assert(s:get_next_incoming_stream(TEST_TIMEOUT))
			local s_headers = assert(s_stream:get_headers(TEST_TIMEOUT))
			assert.same({nil, "upgrade headers MUST be ignored in HTTP 1.0", ce.EINVAL}, {websocket.new_from_stream(s_stream, s_headers)})
			s:close()
			c:close()
		end)
		local function test_invalid_headers(test_name, cb, err)
			it(test_name, function()
				local s, c = new_connection_pair(1.1)
				local c_stream = c:new_stream()
				local headers = correct_headers:clone()
				cb(headers)
				c_stream:write_headers(headers, false)
				local s_stream = assert(s:get_next_incoming_stream(TEST_TIMEOUT))
				local s_headers = assert(s_stream:get_headers(TEST_TIMEOUT))
				assert.same({nil, err, ce.EINVAL}, {websocket.new_from_stream(s_stream, s_headers)})
				s:close()
				c:close()
			end)
		end
		test_invalid_headers("rejects missing upgrade header", function(headers)
			headers:delete("upgrade")
		end, "upgrade header not websocket")
		test_invalid_headers("rejects non-websocket upgrade header", function(headers)
			headers:upsert("upgrade", "notwebsocket")
		end, "upgrade header not websocket")
		test_invalid_headers("rejects missing connection header", function(headers)
			headers:delete("connection")
		end, "connection header doesn't contain upgrade")
		test_invalid_headers("rejects upgrade missing from connection header", function(headers)
			headers:upsert("connection", "other")
		end, "connection header doesn't contain upgrade")
		test_invalid_headers("rejects missing Sec-Websocket-Key header", function(headers)
			headers:delete("sec-websocket-key")
		end, "missing sec-websocket-key")
		test_invalid_headers("rejects missing Sec-Websocket-Version header", function(headers)
			headers:delete("sec-websocket-version")
		end, "unsupported sec-websocket-version")
		test_invalid_headers("rejects unknown Sec-Websocket-Version header", function(headers)
			headers:upsert("sec-websocket-version", "123456")
		end, "unsupported sec-websocket-version")
		test_invalid_headers("rejects invalid Sec-Websocket-Protocol header", function(headers)
			headers:upsert("sec-websocket-protocol", "invalid@protocol")
		end, "invalid sec-websocket-protocol header")
		test_invalid_headers("rejects duplicate Sec-Websocket-Protocol", function(headers)
			headers:upsert("sec-websocket-protocol", "foo, foo")
		end, "duplicate protocol")
	end)
end)
describe("http.websocket module two sided tests", function()
	local onerror  = require "http.connection_common".onerror
	local server = require "http.server"
	local util = require "http.util"
	local websocket = require "http.websocket"
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local ce = require "cqueues.errno"
	local cs = require "cqueues.socket"
	local function new_pair()
		local s, c = ca.assert(cs.pair())
		s:onerror(onerror)
		c:onerror(onerror)
		local ws_server = websocket.new("server")
		ws_server.socket = s
		ws_server.readyState = 1
		local ws_client = websocket.new("client")
		ws_client.socket = c
		ws_client.readyState = 1
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
	it("timeouts return nil, err, errno", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		local ok, _, errno = c:receive(0)
		assert.same(nil, ok)
		assert.same(ce.ETIMEDOUT, errno)
		-- Check it still works afterwards
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
	it("doesn't fail when data contains a \\r\\n", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send("hel\r\nlo"))
			assert.same("wor\r\nld", c:receive())
			assert(c:close())
		end)
		cq:wrap(function()
			assert.same("hel\r\nlo", s:receive())
			assert(s:send("wor\r\nld"))
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	local function send_receive_test(name, data, data_type)
		local function do_test(bad_connection)
			local bname = name
			if bad_connection then
				bname = bname .. ", even if the connection is really bad"
			end
			it(bname, function()
				data_type = data_type or "text"
				if bad_connection then
					local real_xwrite
					local fragments = 100
					local delay = 1 / fragments -- Aim for 1s.
					real_xwrite = cs.interpose("xwrite", function(self, str, mode, timeout)
						if mode ~= "bn" then -- Not interesting, don't throttle.
							return real_xwrite(self, str, mode, timeout)
						end
						local deadline
						if timeout then
							deadline = cqueues.monotime() + timeout
						end
						local ok, op, why
						local nbytes = math.ceil(#str / fragments)
						local before_first = 0
						repeat
							-- Test range at the end to ensure that real_xwrite is called at least once.
							-- We rely on the fact here that :sub sanitizes the input range.
							ok, op, why = real_xwrite(self, str:sub(before_first + 1, before_first + nbytes), mode, deadline and (deadline - cqueues.monotime()))
							if not ok then
								break
							end
							before_first = before_first + nbytes
							cqueues.sleep(delay)
						until before_first > #str
						return ok, op, why
					end)
					finally(function()
						cs.interpose("xwrite", real_xwrite)
					end)
				end
				local cq = cqueues.new()
				local c, s = new_pair()
				cq:wrap(function()
					assert(c:send(data, data_type))
					assert.same({data, data_type}, {assert(c:receive())})
					assert(c:close())
				end)
				cq:wrap(function()
					assert.same({data, data_type}, {assert(s:receive())})
					assert(s:send(data, data_type))
					assert(s:close())
				end)
				assert_loop(cq, TEST_TIMEOUT)
				assert.truthy(cq:empty())
			end)
		end
		do_test(false)
		do_test(true)
	end
	send_receive_test("works with small size frames", "f")
	send_receive_test("works with medium size frames", ("f"):rep(200))
	send_receive_test("works with large size frames", ("f"):rep(100000))
	send_receive_test("works with binary frames", "\0\1\127\255", "binary")
	it("fails when text isn't valid utf8", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send("\230", "text"))
			local ok, _, errno = c:receive()
			assert.same(nil, ok)
			assert.same(1007, errno)
			assert(c:close())
		end)
		cq:wrap(function()
			local ok, _, errno = s:receive()
			assert.same(nil, ok)
			assert.same(1007, errno)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("fails when text isn't valid utf8 (utf16 surrogates)", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send("\237\160\128", "text"))
			local ok, _, errno = c:receive()
			assert.same(nil, ok)
			assert.same(1007, errno)
			assert(c:close())
		end)
		cq:wrap(function()
			local ok, _, errno = s:receive()
			assert.same(nil, ok)
			assert.same(1007, errno)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("doesn't allow invalid utf8 in close messages", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:close(1000, "\237\160\128"))
		end)
		cq:wrap(function()
			local ok, _, errno = s:receive()
			assert.same(nil, ok)
			assert.same(1007, errno)
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
	it("doesn't blow up when given pings", function()
		local cq = cqueues.new()
		local c, s = new_pair()
		cq:wrap(function()
			assert(c:send_ping())
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
			onstream = function(s, stream)
				local headers = assert(stream:get_headers())
				assert.same("http", headers:get(":scheme"))
				local ws = websocket.new_from_stream(stream, headers)
				assert(ws:accept())
				assert(ws:close())
				s:close()
			end;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			assert_loop(s)
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
		local new_headers = require "http.headers".new
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
			onstream = function(s, stream)
				local headers = assert(stream:get_headers())
				local ws = websocket.new_from_stream(stream, headers)
				local response_headers = new_headers()
				response_headers:upsert(":status", "101")
				response_headers:upsert("server", "lua-http websocket test")
				assert(ws:accept {
					headers = response_headers;
					protocols = {"my awesome-protocol", "foo"};
				})
				-- Should prefer client protocol preference
				assert.same("foo", ws.protocol)
				assert(ws:close())
				s:close()
			end;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local ws = websocket.new_from_uri({
				scheme = "ws";
				host = host;
				port = port;
			}, {"foo", "my-awesome-protocol", "bar"})
			assert(ws:connect())
			assert.same("foo", ws.protocol)
			assert.same("lua-http websocket test", ws.headers:get("server"))
			assert(ws:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
