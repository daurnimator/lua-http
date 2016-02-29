local TEST_TIMEOUT = 2
describe("http.socks module", function()
	local http_socks = require "http.socks"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local ce = require "cqueues.errno"
	local IPv4address = require "lpeg_patterns.IPv4".IPv4address
	local IPv6address = require "lpeg_patterns.IPv6".IPv6address
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	it("can negotiate a IPv4 connection with no auth", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			assert(http_socks.socks5_negotiate(c, {
				host = IPv4address:match "127.0.0.1";
				port = 123;
			}))
		end)
		cq:wrap(function()
			assert.same("\5", s:read(1))
			local n = assert(s:read(1)):byte()
			local available_auth = assert(s:read(n))
			assert.same("\0", available_auth)
			assert(s:xwrite("\5\0", "n"))
			assert.same("\5\1\0\1\127\0\0\1\0\123", s:read(10))
			assert(s:xwrite("\5\0\0\1\127\0\0\1\12\34", "n"))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("can negotiate a IPv6 connection with username+password auth", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			assert(http_socks.socks5_negotiate(c, {
				host = IPv6address:match "::1";
				port = 123;
				username = "open";
				password = "sesame";
			}))
		end)
		cq:wrap(function()
			assert.same("\5", s:read(1))
			local n = assert(s:read(1)):byte()
			local available_auth = assert(s:read(n))
			assert.same("\0\2", available_auth)
			assert(s:xwrite("\5\2", "n"))
			assert.same("\1\4open\6sesame", s:read(13))
			assert(s:xwrite("\1\0", "n"))
			assert.same("\5\1\0\4\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\123", s:read(22))
			assert(s:xwrite("\5\0\0\4\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\12\34", "n"))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("incorrect username+password fails with EACCES", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			assert.same({nil, ce.EACCES}, { http_socks.socks5_negotiate(c, {
				host = "unused";
				port = 123;
				username = "open";
				password = "sesame";
			})})
		end)
		cq:wrap(function()
			assert.same("\5", s:read(1))
			local n = assert(s:read(1)):byte()
			local available_auth = assert(s:read(n))
			assert.same("\0\2", available_auth)
			assert(s:xwrite("\5\2", "n"))
			assert.same("\1\4open\6sesame", s:read(13))
			assert(s:xwrite("\1\1", "n"))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
end)
