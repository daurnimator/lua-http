local TEST_TIMEOUT = 2
describe("http.tls module", function()
	local tls = require "http.tls"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local openssl_ctx = require "openssl.ssl.context"
	local openssl_pkey = require "openssl.pkey"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	it("banned ciphers list denies a negotiated banned cipher", function()
		local c, s = cs.pair()
		local cq = cqueues.new()
		cq:wrap(function()
			local ctx = openssl_ctx.new("TLSv1", false)
			ctx:setCipherList("EXPORT:eNULL:!EC:!AES") -- Purposefully insecure!
			assert(c:starttls(ctx))
			local ssl = assert(s:checktls())
			local cipher = ssl:getCipherInfo()
			assert(tls.banned_ciphers[cipher.name])
		end)
		cq:wrap(function()
			local ctx = openssl_ctx.new("TLSv1", true)
			ctx:setEphemeralKey(openssl_pkey.new{ type = "EC", curve = "prime256v1" })
			ctx:setCipherList("ALL:eNULL") -- Purposefully insecure!
			assert(s:starttls(ctx))
			local ssl = assert(s:checktls())
			local cipher = ssl:getCipherInfo()
			assert(tls.banned_ciphers[cipher.name])
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("can create a new client context", function()
		tls.new_client_context()
	end)
	it("can create a new server context", function()
		tls.new_server_context()
	end)
end)
