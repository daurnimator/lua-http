local TEST_TIMEOUT = 2
describe("http1 stream", function()
	local h1_connection = require "http.h1_connection"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local cc = require "cqueues.condition"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	local function new_pair(version)
		local s, c = cs.pair()
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end
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
		cq:wrap(function()
			local a = client:new_stream()
			local ah = new_headers()
			ah:append(":method", "GET")
			ah:append(":path", "/a")
			assert(a:write_headers(ah, true))
			local b = client:new_stream()
			local bh = new_headers()
			bh:append(":method", "POST")
			bh:append(":path", "/b")
			assert(b:write_headers(bh, false))
			assert(b:write_chunk("this is some POST data", true))
			local c = client:new_stream()
			local ch = new_headers()
			ch:append(":method", "GET")
			ch:append(":path", "/c")
			assert(c:write_headers(ch, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		-- All requests read; now for responses
		-- Don't want /a to be first.
		local sync = cc.new()
		cq:wrap(function()
			if sync then sync:wait() end
			assert(streams["/a"]:write_headers(new_headers(), true))
		end)
		cq:wrap(function()
			sync:signal(1); sync = nil;
			assert(streams["/b"]:write_headers(new_headers(), true))
		end)
		cq:wrap(function()
			assert(streams["/c"]:write_headers(new_headers(), true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("allows 100 continue", function()
		local server, client = new_pair(1.1)
		local cq = cqueues.new()
		cq:wrap(function()
			local a = client:new_stream()
			local h = new_headers()
			h:append(":method", "POST")
			h:append(":path", "/a")
			h:append("expect", "100-continue")
			assert(a:write_headers(h, false))
			assert(assert(a:get_headers()):get(":status") == "100")
			assert(a:write_chunk("body", true))
			assert(assert(a:get_headers()):get(":status") == "200")
			assert(a:get_next_chunk() == "done")
			assert(a:get_next_chunk() == nil)
		end)
		cq:wrap(function()
			local b = assert(server:get_next_incoming_stream())
			assert(b:get_headers())
			assert(b:write_continue())
			assert(b:get_next_chunk() == "body")
			assert(b:get_next_chunk() == nil)
			local h = new_headers()
			h:append(":status", "200")
			assert(b:write_headers(h, false))
			assert(b:write_chunk("done", true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
