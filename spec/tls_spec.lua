describe("http.tls module", function()
	local tls = require "http.tls"
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cs = require "cqueues.socket"
	local openssl_ctx = require "openssl.ssl.context"
	local openssl_pkey = require "openssl.pkey"
	local openssl_x509 = require "openssl.x509"
	it("banned ciphers list denies a negotiated banned cipher", function()
		local banned_cipher_list do
			local t = {}
			for cipher in pairs(tls.banned_ciphers) do
				table.insert(t, cipher)
			end
			banned_cipher_list = table.concat(t, ":")
		end
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			local ctx = openssl_ctx.new("TLS", false)
			assert(c:starttls(ctx))
			local ssl = assert(s:checktls())
			local cipher = ssl:getCipherInfo()
			assert(tls.banned_ciphers[cipher.name])
		end)
		cq:wrap(function()
			local ctx = openssl_ctx.new("TLS", true)
			ctx:setOptions(openssl_ctx.OP_NO_TLSv1_3)
			ctx:setCipherList(banned_cipher_list)
			ctx:setEphemeralKey(openssl_pkey.new{ type = "EC", curve = "prime256v1" })
			local crt = openssl_x509.new()
			local key = openssl_pkey.new({type="RSA", bits=2048})
			crt:setPublicKey(key)
			crt:sign(key)
			assert(ctx:setPrivateKey(key))
			assert(ctx:setCertificate(crt))
			assert(s:starttls(ctx))
			local ssl = assert(s:checktls())
			local cipher = ssl:getCipherInfo()
			assert(tls.banned_ciphers[cipher.name])
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		s:close()
		c:close()
	end)
	it("can create a new client context", function()
		tls.new_client_context()
	end)
	it("can create a new server context", function()
		tls.new_server_context()
	end)
end)
