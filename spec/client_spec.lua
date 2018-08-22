describe("http.client module", function()
	local client = require "http.client"
	local http_connection_common = require "http.connection_common"
	local http_h1_connection = require "http.h1_connection"
	local http_h2_connection = require "http.h2_connection"
	local http_headers = require "http.headers"
	local http_tls = require "http.tls"
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cs = require "cqueues.socket"
	local openssl_pkey = require "openssl.pkey"
	local openssl_ctx = require "openssl.ssl.context"
	local openssl_x509 = require "openssl.x509"
	it("invalid network parameters return nil, err, errno", function()
		-- Invalid network parameters will return nil, err, errno
		local ok, err, errno = client.connect{host="127.0.0.1", port="invalid"}
		assert.same(nil, ok)
		assert.same("string", type(err))
		assert.same("number", type(errno))
	end)
	local function send_request(conn)
		local stream = conn:new_stream()
		local req_headers = http_headers.new()
		req_headers:append(":authority", "myauthority")
		req_headers:append(":method", "GET")
		req_headers:append(":path", "/")
		req_headers:append(":scheme", conn:checktls() and "https" or "http")
		assert(stream:write_headers(req_headers, true))
		local res_headers = assert(stream:get_headers())
		assert.same("200", res_headers:get(":status"))
	end
	local function test_pair(client_options, server_func)
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new();
		cq:wrap(function()
			local conn = assert(client.negotiate(c, client_options))
			send_request(conn)
		end)
		cq:wrap(function()
			s = server_func(s)
			if not s then return end
			if client_options.tls then
				local ssl = s:checktls()
				assert.same(client_options.sendname, ssl:getHostName())
			end
			local stream = assert(s:get_next_incoming_stream())
			assert(stream:get_headers())
			local res_headers = http_headers.new()
			res_headers:append(":status", "200")
			assert(stream:write_headers(res_headers, true))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		c:close()
		s:close()
	end
	local function new_server_ctx()
		local key = openssl_pkey.new()
		local crt = openssl_x509.new()
		crt:setPublicKey(key)
		crt:sign(key)
		local ctx = http_tls.new_server_context()
		assert(ctx:setPrivateKey(key))
		assert(ctx:setCertificate(crt))
		return ctx
	end
	it("works with an http/1.1 server", function()
		test_pair({}, function(s)
			return http_h1_connection.new(s, "server", 1.1)
		end)
	end)
	it("works with an http/2 server", function()
		test_pair({
			version = 2;
		}, function(s)
			return http_h2_connection.new(s, "server", {})
		end)
	end)
	it("fails with unknown http version", function()
		assert.has.error(function()
			test_pair({
				version = 5;
			}, function() end)
		end)
	end)
	it("works with an https/1.1 server", function()
		local client_ctx = http_tls.new_client_context()
		client_ctx:setVerify(openssl_ctx.VERIFY_NONE)
		test_pair({
			tls = true;
			ctx = client_ctx;
			sendname = "mysendname";
		}, function(s)
			assert(s:starttls(new_server_ctx()))
			return http_h1_connection.new(s, "server", 1.1)
		end)
	end)
	-- pending as older openssl (used by e.g. travis-ci) doesn't have any non-disallowed ciphers
	pending("works with an https/2 server", function()
		local client_ctx = http_tls.new_client_context()
		client_ctx:setVerify(openssl_ctx.VERIFY_NONE)
		test_pair({
			tls = true;
			ctx = client_ctx;
			sendname = "mysendname";
			version = 2;
		}, function(s)
			assert(s:starttls(new_server_ctx()))
			return http_h2_connection.new(s, "server", {})
		end)
	end)
	it("reports errors from :starttls", function()
		-- default settings should fail as it should't allow self-signed
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new();
		cq:wrap(function()
			local ok, err = client.negotiate(c, {
				tls = true;
			})
			assert.falsy(ok)
			assert.truthy(err:match("starttls: "))
		end)
		cq:wrap(function()
			s:onerror(http_connection_common.onerror)
			local ok, err = s:starttls()
			assert.falsy(ok)
			assert.truthy(err:match("starttls: "))
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		c:close()
		s:close()
	end)
end)
