describe("http2 connection", function()
	local h2_connection = require "http.h2_connection"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local cc = require "cqueues.condition"
	local ce = require "cqueues.errno"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	it("Rejects invalid #preface", function()
		local function test_preface(text)
			local c, s = cs.pair()
			local cq = cqueues.new()
			cq:wrap(function()
				assert.has.errors(function()
					h2_connection.new(s, "server")
				end)
			end)
			cq:wrap(function()
				c:xwrite(text, "n")
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end
		test_preface("invalid preface")
		test_preface("PRI * HTTP/2.0\r\n\r\nSM\r\n\r") -- missing last \n
		test_preface(("long string"):rep(1000))
	end)
	it("Can #ping back and forth", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			c = h2_connection.new(c, "client")
			cq:wrap(function()
				for _=1, 10 do
					assert(c:ping())
				end
				assert(c:shutdown())
			end)
			assert_loop(c)
			assert(c:close())
		end)
		cq:wrap(function()
			s = h2_connection.new(s, "server")
			cq:wrap(function()
				assert(s:ping())
			end)
			assert_loop(s)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("Can #ping without a driving loop", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			c = h2_connection.new(c, "client")
			for _=1, 10 do
				assert(c:ping())
			end
			assert(c:close())
		end)
		cq:wrap(function()
			s = h2_connection.new(s, "server")
			assert_loop(s)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("waits for peer flow #credits", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		local client_stream
		cq:wrap(function()
			c = h2_connection.new(c, "client")

			client_stream = c:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":path", "/")
			assert(client_stream:write_headers(req_headers, false))
			local ok, cond = 0, cc.new()
			cq:wrap(function()
				ok = ok + 1
				if ok == 2 then cond:signal() end
				assert(c.peer_flow_credits_increase:wait(TEST_TIMEOUT/2), "no connection credits")
			end)
			cq:wrap(function()
				ok = ok + 1
				if ok == 2 then cond:signal() end
				assert(client_stream.peer_flow_credits_increase:wait(TEST_TIMEOUT/2), "no stream credits")
			end)
			cond:wait() -- wait for above threads to get scheduled
			assert(client_stream:write_chunk(("really long string"):rep(1e4), true))
			assert_loop(c)
			assert(c:close())
		end)
		local len = 0
		cq:wrap(function()
			s = h2_connection.new(s, "server")
			local stream = assert(s:get_next_incoming_stream())
			while true do
				local chunk, err = stream:get_next_chunk()
				if chunk == nil then
					if err == ce.EPIPE then
						break
					else
						error(err)
					end
				end
				len = len + #chunk
			end
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.same(client_stream.stats_sent, len)
	end)
	it("#settings frame sizes", function()
		local c = cs.pair()
		-- should error if < 16384
		assert.has.errors(function()
			h2_connection.new(c, "client", {[0x5]=1}, TEST_TIMEOUT)
		end)
		assert.has.errors(function()
			h2_connection.new(c, "client", {[0x5]=16383}, TEST_TIMEOUT)
		end)
		-- should error if > 2^24
		assert.has.errors(function()
			h2_connection.new(c, "client", {[0x5]=2^24}, TEST_TIMEOUT)
		end)
		assert.has.errors(function()
			h2_connection.new(c, "client", {[0x5]=2^32}, TEST_TIMEOUT)
		end)
		assert.has.errors(function()
			h2_connection.new(c, "client", {[0x5]=math.huge}, TEST_TIMEOUT)
		end)
	end)
end)
