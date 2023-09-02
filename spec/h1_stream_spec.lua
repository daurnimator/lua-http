describe("http1 stream", function()
	local h1_connection = require "http.h1_connection"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cc = require "cqueues.condition"
	local ce = require "cqueues.errno"
	local cs = require "cqueues.socket"
	local function new_pair(version)
		local s, c = ca.assert(cs.pair())
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end
	it("allows resuming :read_headers", function()
		local server, client = new_pair(1.1)
		client = client:take_socket()
		assert(client:xwrite("GET / HTTP/1.1\r\n", "n"))
		local stream = server:get_next_incoming_stream()
		assert.same(ce.ETIMEDOUT, select(3, stream:read_headers(0.001)))
		assert(client:xwrite("Foo: bar\r\n", "n"))
		assert.same(ce.ETIMEDOUT, select(3, stream:read_headers(0.001)))
		assert(client:xwrite("\r\n", "n"))
		local h = assert(stream:read_headers(0.01))
		assert.same("/", h:get(":path"))
		assert.same("bar", h:get("foo"))
	end)
	it("CONNECT requests should have an host header on the wire", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "CONNECT")
			req_headers:append(":scheme", "http")
			req_headers:append(":authority", "myauthority:8888")
			assert(stream:write_headers(req_headers, true))
			stream:shutdown()
		end)
		cq:wrap(function()
			local method, path, httpversion = assert(server:read_request_line())
			assert.same("CONNECT", method)
			assert.same("myauthority:8888", path)
			assert.same(1.1, httpversion)
			local k, v = assert(server:read_header())
			assert.same("host", k)
			assert.same("myauthority:8888", v)
			server:shutdown()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("Writing to a shutdown connection returns EPIPE", function()
		local server, client = new_pair(1.1)
		local stream = client:new_stream()
		client:shutdown()
		local headers = new_headers()
		headers:append(":method", "GET")
		headers:append(":scheme", "http")
		headers:append(":authority", "myauthority")
		headers:append(":path", "/a")
		assert.same(ce.EPIPE, select(3, stream:write_headers(headers, true)))
		client:close()
		server:close()
	end)
	it("shutdown of an open server stream sends an automatic 503", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":authority", "myauthority")
			req_headers:append(":path", "/a")
			assert(stream:write_headers(req_headers, true))
			local res_headers = assert(stream:get_headers())
			assert.same("503", res_headers:get(":status"))
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			stream:shutdown()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("shutdown of an open server stream with client protocol errors sends an automatic 400", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			assert(client:write_request_line("GET", "/", 1.1))
			assert(client.socket:xwrite(":not a valid header\r\n", "bn"))
			local _, status_code = assert(client:read_status_line())
			assert.same("400", status_code)
		end)
		cq:wrap(function()
			local stream = assert(server:get_next_incoming_stream())
			assert.same(ce.EILSEQ, select(3, stream:get_headers()))
			stream:shutdown()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it(":unget returns truthy value on success", function()
		local server, client = new_pair(1.1)
		local stream = client:new_stream()
		assert.truthy(stream:unget("foo"))
		assert.same("foo", stream:get_next_chunk())
		client:close()
		server:close()
	end)
	it("doesn't hang when :shutdown is called when waiting for headers", function()
		local server, client = new_pair(1.1)
		local stream = client:new_stream()
		local headers = new_headers()
		headers:append(":method", "GET")
		headers:append(":scheme", "http")
		headers:append(":authority", "myauthority")
		headers:append(":path", "/a")
		assert(stream:write_headers(headers, true))
		local cq = cqueues.new():wrap(function()
			stream:shutdown()
		end)
		assert_loop(cq, 0.01)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("inserts connection: close if the connection is going to be closed afterwards", function()
		local server, client = new_pair(1.0)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":authority", "myauthority")
			req_headers:append(":path", "/a")
			assert(stream:write_headers(req_headers, true))
			local res_headers = assert(stream:get_headers())
			assert.same("close", res_headers:get("connection"))
			assert.same({}, {stream:get_next_chunk()})
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			local res_headers = new_headers()
			res_headers:append(":status", "200")
			assert(stream:write_headers(res_headers, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("returns multiple chunks on slow 'connection: close' bodies", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":authority", "myauthority")
			req_headers:append(":path", "/a")
			assert(stream:write_headers(req_headers, true))
			assert(stream:get_headers())
			assert.same("foo", stream:get_next_chunk())
			assert.same("bar", stream:get_next_chunk())
			assert.same({}, {stream:get_next_chunk()})
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			local res_headers = new_headers()
			res_headers:append(":status", "200")
			res_headers:append("connection", "close")
			assert(stream:write_headers(res_headers, false))
			assert(stream:write_chunk("foo", false))
			cqueues.sleep(0.1)
			assert(stream:write_chunk("bar", true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("queues up trailers and returns them from :get_headers", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local headers = new_headers()
			headers:append(":method", "GET")
			headers:append(":scheme", "http")
			headers:append(":authority", "myauthority")
			headers:append(":path", "/a")
			headers:append("transfer-encoding", "chunked")
			assert(stream:write_headers(headers, false))
			local trailers = new_headers()
			trailers:append("foo", "bar")
			assert(stream:write_headers(trailers, true))
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			assert.same("", assert(stream:get_body_as_string()))
			-- check remote end has completed (and hence the following :get_headers won't be reading from socket)
			assert.same("half closed (remote)", stream.state)
			local trailers = assert(stream:get_headers())
			assert.same("bar", trailers:get("foo"))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("doesn't return from last get_next_chunk until trailers are read", function()
		local server, client = new_pair(1.1)
		assert(client:write_request_line("GET", "/a", client.version, TEST_TIMEOUT))
		assert(client:write_header("transfer-encoding", "chunked", TEST_TIMEOUT))
		assert(client:write_headers_done(TEST_TIMEOUT))
		assert(client:write_body_chunk("foo", nil, TEST_TIMEOUT))
		assert(client:write_body_last_chunk(nil, TEST_TIMEOUT))
		assert(client:write_header("sometrailer", "bar", TEST_TIMEOUT))
		assert(client:flush(TEST_TIMEOUT))
		local server_stream = server:get_next_incoming_stream(0.01)
		assert(server_stream:get_headers(0.01))
		assert.same("foo", server_stream:get_next_chunk(0.01))
		-- Shouldn't return `nil` (indicating EOF) until trailers are completely read.
		assert.same(ce.ETIMEDOUT, select(3, server_stream:get_next_chunk(0.01)))
		assert.same(ce.ETIMEDOUT, select(3, server_stream:get_headers(0.01)))
		assert(client:write_headers_done(TEST_TIMEOUT))
		assert.same({}, {server_stream:get_next_chunk(0.01)})
		local trailers = assert(server_stream:get_headers(0))
		assert.same("bar", trailers:get("sometrailer"))
		server:close()
		client:close()
	end)
	it("waits for trailers when :get_headers is run in a second thread", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local headers = new_headers()
			headers:append(":method", "GET")
			headers:append(":scheme", "http")
			headers:append(":authority", "myauthority")
			headers:append(":path", "/a")
			headers:append("transfer-encoding", "chunked")
			assert(stream:write_headers(headers, false))
			local trailers = new_headers()
			trailers:append("foo", "bar")
			assert(stream:write_headers(trailers, true))
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			cqueues.running():wrap(function()
				local trailers = assert(stream:get_headers())
				assert.same("bar", trailers:get("foo"))
			end)
			cqueues.sleep(0.1)
			assert.same("", assert(stream:get_body_as_string()))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("Can read content-length delimited stream", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			do
				local stream = client:new_stream()
				local headers = new_headers()
				headers:append(":method", "GET")
				headers:append(":scheme", "http")
				headers:append(":authority", "myauthority")
				headers:append(":path", "/a")
				headers:append("content-length", "100")
				assert(stream:write_headers(headers, false))
				assert(stream:write_chunk(("b"):rep(100), true))
			end
			do
				local stream = client:new_stream()
				local headers = new_headers()
				headers:append(":method", "GET")
				headers:append(":scheme", "http")
				headers:append(":authority", "myauthority")
				headers:append(":path", "/b")
				headers:append("content-length", "0")
				assert(stream:write_headers(headers, true))
			end
		end)
		cq:wrap(function()
			do
				local stream = server:get_next_incoming_stream()
				local headers = assert(stream:read_headers())
				local body = assert(stream:get_body_as_string())
				assert.same(100, tonumber(headers:get("content-length")))
				assert.same(100, #body)
			end
			do
				local stream = server:get_next_incoming_stream()
				local headers = assert(stream:read_headers())
				local body = assert(stream:get_body_as_string())
				assert.same(0, tonumber(headers:get("content-length")))
				assert.same(0, #body)
			end
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("Doesn't hang when a content-length delimited stream is closed", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = client:new_stream()
			local headers = new_headers()
			headers:append(":method", "GET")
			headers:append(":scheme", "http")
			headers:append(":authority", "myauthority")
			headers:append(":path", "/a")
			assert(stream:write_headers(headers, true))
		end)
		cq:wrap(function()
			local stream = server:get_next_incoming_stream()
			assert(stream:get_headers())
			local res_headers = new_headers()
			res_headers:append(":status", "200")
			res_headers:append("content-length", "100")
			assert(stream:write_headers(res_headers, false))
			assert(stream:write_chunk("foo", false))
			assert(stream:shutdown())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("allows pipelining", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		local streams = {}
		cq:wrap(function()
			local x = server:get_next_incoming_stream()
			local xh = assert(x:read_headers())
			while x:get_next_chunk() do end
			streams[xh:get(":path")] = x
		end)
		cq:wrap(function()
			local y = server:get_next_incoming_stream()
			local yh = assert(y:read_headers())
			while y:get_next_chunk() do end
			streams[yh:get(":path")] = y
		end)
		cq:wrap(function()
			local z = server:get_next_incoming_stream()
			local zh = assert(z:read_headers())
			while z:get_next_chunk() do end
			streams[zh:get(":path")] = z
		end)
		local client_sync = cc.new()
		cq:wrap(function()
			if client_sync then client_sync:wait() end
			local a = client:new_stream()
			local ah = new_headers()
			ah:append(":method", "GET")
			ah:append(":scheme", "http")
			ah:append(":authority", "myauthority")
			ah:append(":path", "/a")
			assert(a:write_headers(ah, true))
		end)
		cq:wrap(function()
			client_sync:signal(); client_sync = nil;
			local b = client:new_stream()
			local bh = new_headers()
			bh:append(":method", "POST")
			bh:append(":scheme", "http")
			bh:append(":authority", "myauthority")
			bh:append(":path", "/b")
			assert(b:write_headers(bh, false))
			cqueues.sleep(0.01)
			assert(b:write_chunk("this is some POST data", true))
		end)
		cq:wrap(function()
			local c = client:new_stream()
			local ch = new_headers()
			ch:append(":method", "GET")
			ch:append(":scheme", "http")
			ch:append(":authority", "myauthority")
			ch:append(":path", "/c")
			assert(c:write_headers(ch, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		-- All requests read; now for responses
		-- Don't want /a to be first.
		local server_sync = cc.new()
		cq:wrap(function()
			if server_sync then server_sync:wait() end
			local h = new_headers()
			h:append(":status", "200")
			assert(streams["/a"]:write_headers(h, true))
		end)
		cq:wrap(function()
			server_sync:signal(); server_sync = nil;
			local h = new_headers()
			h:append(":status", "200")
			assert(streams["/b"]:write_headers(h, true))
		end)
		cq:wrap(function()
			if server_sync then server_sync:wait() end
			local h = new_headers()
			h:append(":status", "200")
			assert(streams["/c"]:write_headers(h, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("modifying pipelined headers doesn't affect what's sent", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local a = client:new_stream()
			local b = client:new_stream()
			local c = client:new_stream()

			do
				local h = new_headers()
				h:append(":method", "POST")
				h:append(":scheme", "http")
				h:append(":authority", "myauthority")
				h:append(":path", "/")
				h:upsert("id", "a")
				assert(a:write_headers(h, false))
				cq:wrap(function()
					cq:wrap(function()
						cq:wrap(function()
							assert(a:write_chunk("a", true))
						end)
						h:upsert("id", "c")
						assert(c:write_headers(h, false))
						assert(c:write_chunk("c", true))
					end)
					h:upsert("id", "b")
					assert(b:write_headers(h, false))
					assert(b:write_chunk("b", true))
				end)
			end
			do
				local h = assert(a:get_headers())
				assert.same("a", h:get "id")
			end
			do
				local h = assert(b:get_headers())
				assert.same("b", h:get "id")
			end
			do
				local h = assert(c:get_headers())
				assert.same("c", h:get "id")
			end
		end)
		cq:wrap(function()
			local h = new_headers()
			h:append(":status", "200")

			local a = assert(server:get_next_incoming_stream())
			assert.same("a", assert(a:get_headers()):get "id")
			assert.same("a", a:get_body_as_string())
			cq:wrap(function()
				h:upsert("id", "a")
				assert(a:write_headers(h, true))
			end)

			local b = assert(server:get_next_incoming_stream())
			assert.same("b", assert(b:get_headers()):get "id")
			assert.same("b", b:get_body_as_string())
			h:upsert("id", "b")
			assert(b:write_headers(h, true))

			local c = assert(server:get_next_incoming_stream())
			assert.same("c", assert(c:get_headers()):get "id")
			assert.same("c", c:get_body_as_string())
			assert(c:get_headers())
			h:upsert("id", "c")
			assert(c:write_headers(h, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("allows 100 continue", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local a = client:new_stream()
			local h = new_headers()
			h:append(":method", "POST")
			h:append(":scheme", "http")
			h:append(":authority", "myauthority")
			h:append(":path", "/a")
			h:append("expect", "100-continue")
			assert(a:write_headers(h, false))
			assert(assert(a:get_headers()):get(":status") == "100")
			assert(a:write_chunk("body", true))
			assert(assert(a:get_headers()):get(":status") == "200")
			assert(a:get_next_chunk() == "done")
			assert.same({}, {a:get_next_chunk()})
		end)
		cq:wrap(function()
			local b = assert(server:get_next_incoming_stream())
			assert(b:get_headers())
			assert(b:write_continue())
			assert(b:get_next_chunk() == "body")
			assert.same({}, {b:get_next_chunk()})
			local h = new_headers()
			h:append(":status", "200")
			assert(b:write_headers(h, false))
			assert(b:write_chunk("done", true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
	it("doesn't allow sending body before headers", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local a = client:new_stream()
			local h = new_headers()
			h:append(":method", "GET")
			h:append(":scheme", "http")
			h:append(":authority", "myauthority")
			h:append(":path", "/")
			assert(a:write_headers(h, true))
		end)
		cq:wrap(function()
			local b = assert(server:get_next_incoming_stream())
			b.use_zlib = false
			assert(b:get_headers())
			assert.has.errors(function() b:write_chunk("", true) end)
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		server:close()
		client:close()
	end)
end)
