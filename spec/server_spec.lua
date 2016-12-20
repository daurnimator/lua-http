describe("http.server module", function()
	local http_server = require "http.server"
	local http_client = require "http.client"
	local http_tls = require "http.tls"
	local http_headers = require "http.headers"
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local ce = require "cqueues.errno"
	local cs = require "cqueues.socket"
	local openssl_ctx = require "openssl.ssl.context"
	local non_verifying_tls_context = http_tls.new_client_context()
	non_verifying_tls_context:setVerify(openssl_ctx.VERIFY_NONE)
	it("rejects missing 'ctx' field", function()
		local s, c = ca.assert(cs.pair())
		assert.has.errors(function()
			http_server.new {
				socket = s;
				onstream = error;
			}
		end)
		s:close()
		c:close()
	end)
	it("rejects invalid 'cq' field", function()
		local s, c = ca.assert(cs.pair())
		assert.has.errors(function()
			http_server.new {
				socket = s;
				tls = false;
				onstream = error;
				cq = 5;
			}
		end)
		s:close()
		c:close()
	end)
	it("__tostring works", function()
		local s, c = ca.assert(cs.pair())
		s = http_server.new {
			socket = s;
			tls = false;
			onstream = error;
		}
		assert.same("http.server{", tostring(s):match("^.-%{"))
		s:close()
		c:close()
	end)
	it(":onerror with no arguments doesn't clear", function()
		local s, c = ca.assert(cs.pair())
		s = http_server.new {
			socket = s;
			tls = false;
			onstream = error;
		}
		local onerror = s:onerror()
		assert.same("function", type(onerror))
		assert.same(onerror, s:onerror())
		s:close()
		c:close()
	end)
	local function simple_test(family, tls, client_version, server_version)
		local cq = cqueues.new()
		local options = {
			family = family;
			tls = tls;
			version = server_version;
		}
		if family == cs.AF_UNIX then
			local socket_path = os.tmpname()
			finally(function()
				os.remove(socket_path)
			end)
			options.path = socket_path
			options.unlink = true
		else
			options.host = "localhost"
			options.port = 0
		end
		local onstream = spy.new(function(s, stream)
			stream:get_headers()
			stream:shutdown()
			s:close()
		end)
		options.onstream = onstream
		local s = assert(http_server.listen(options))
		assert(s:listen())
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local client_path
			local client_family, client_host, client_port = s:localname()
			if client_family == cs.AF_UNIX then
				client_path = client_host
				client_host = nil
			end
			local client_options = {
				family = client_family;
				host = client_host;
				port = client_port;
				path = client_path;
				tls = tls;
				ctx = non_verifying_tls_context;
				version = client_version;
			}
			local conn = assert(http_client.connect(client_options))
			local stream = conn:new_stream()
			local headers = http_headers.new()
			headers:append(":authority", "myauthority")
			headers:append(":method", "GET")
			headers:append(":path", "/")
			headers:append(":scheme", "http")
			assert(stream:write_headers(headers, true))
			stream:get_headers()
			if server_version then
				if conn.version == 1.1 then
					-- 1.1 client might have 1.0 server
					assert.same(server_version, stream.peer_version)
				else
					assert.same(server_version, conn.version)
				end
			end
			conn:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.spy(onstream).was.called()
	end
	it("works with plain http 1.1 using IP", function()
		simple_test(cs.AF_INET, false, 1.1)
	end)
	it("works with https 1.1 using IP", function()
		simple_test(cs.AF_INET, true, 1.1)
	end)
	it("works with plain http 2.0 using IP", function()
		simple_test(cs.AF_INET, false, 2.0)
	end);
	(http_tls.has_alpn and it or pending)("works with https 2.0 using IP", function()
		simple_test(cs.AF_INET, true, 2.0)
	end)
	--[[ TLS tests are pending for now as UNIX sockets don't automatically
	generate a TLS context ]]
	it("works with plain http 1.1 using UNIX socket", function()
		simple_test(cs.AF_UNIX, false, 1.1)
	end)
	pending("works with https 1.1 using UNIX socket", function()
		simple_test(cs.AF_UNIX, true, 1.1)
	end)
	it("works with plain http 2.0 using UNIX socket", function()
		simple_test(cs.AF_UNIX, false, 2.0)
	end);
	pending("works with https 2.0 using UNIX socket", function()
		simple_test(cs.AF_UNIX, true, 2.0)
	end)
	describe("pin server version", function()
		it("works when set to http 1.0 without TLS", function()
			simple_test(cs.AF_INET, false, nil, 1.0)
		end)
		it("works when set to http 1.1 without TLS", function()
			simple_test(cs.AF_INET, false, nil, 1.1)
		end)
		it("works when set to http 1.0 with TLS", function()
			simple_test(cs.AF_INET, true, nil, 1.0)
		end)
		it("works when set to http 1.1 with TLS", function()
			simple_test(cs.AF_INET, true, nil, 1.1)
		end)
		-- This test doesn't seem to work on travis
		pending("works when set to http 2.0 with TLS", function()
			simple_test(cs.AF_INET, true, nil, 2.0)
		end)
	end);
	(http_tls.has_alpn and it or pending)("works to set server version when alpn proto is not a normal http one", function()
		local ctx = http_tls.new_client_context()
		ctx:setAlpnProtos { "foo" }
		simple_test(cs.AF_INET, ctx, nil, nil)
		simple_test(cs.AF_INET, ctx, nil, 1.1)
		simple_test(cs.AF_INET, ctx, 2.0, 2.0)
	end)
	it("taking socket from underlying connection is handled well by server", function()
		local cq = cqueues.new()
		local onstream = spy.new(function(s, stream)
			local sock = stream.connection:take_socket()
			s:close()
			assert.same("test", sock:read("*a"))
			sock:close()
		end);
		local s = assert(http_server.listen {
			host = "localhost";
			port = 0;
			onstream = onstream;
		})
		assert(s:listen())
		local _, host, port = s:localname()
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local sock = cs.connect {
				host = host;
				port = port;
			}
			assert(sock:write("test"))
			assert(sock:flush())
			sock:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.spy(onstream).was.called()
	end)
	it("an idle http2 stream doesn't block the server", function()
		local s = assert(http_server.listen {
			host = "localhost";
			port = 0;
			onstream = function(_, stream)
				if stream.id == 1 then
					stream:get_next_chunk()
				else
					assert.same(3, stream.id)
					assert.same({}, {stream:get_next_chunk()})
					local headers = http_headers.new()
					headers:append(":status", "200")
					assert(stream:write_headers(headers, true))
				end
			end;
		})
		assert(s:listen())
		local client_family, client_host, client_port = s:localname()
		local conn = assert(http_client.connect({
			family = client_family;
			host = client_host;
			port = client_port;
			version = 2;
		}))
		local cq = cqueues.new()
		cq:wrap(function()
			assert_loop(s)
		end)
		cq:wrap(function()
			local headers = http_headers.new()
			headers:append(":authority", "myauthority")
			headers:append(":method", "GET")
			headers:append(":path", "/")
			headers:append(":scheme", "http")
			local stream1 = assert(conn:new_stream())
			assert(stream1:write_headers(headers, false))
			local stream2 = assert(conn:new_stream())
			assert(stream2:write_headers(headers, true))
			assert(stream2:get_headers())
			conn:close()
			s:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("allows pausing+resuming the server", function()
		local s = assert(http_server.listen {
			host = "localhost";
			port = 0;
			onstream = function(_, stream)
				assert(stream:get_headers())
				local headers = http_headers.new()
				headers:append(":status", "200")
				assert(stream:write_headers(headers, true))
			end;
		})
		assert(s:listen())
		local client_family, client_host, client_port = s:localname()
		local client_options = {
			family = client_family;
			host = client_host;
			port = client_port;
		}
		local headers = http_headers.new()
		headers:append(":authority", "myauthority")
		headers:append(":method", "GET")
		headers:append(":path", "/")
		headers:append(":scheme", "http")

		local cq = cqueues.new()
		cq:wrap(function()
			assert_loop(s)
		end)
		local function do_req(timeout)
			local conn = assert(http_client.connect(client_options))
			local stream = assert(conn:new_stream())
			assert(stream:write_headers(headers, true))
			local ok, err, errno = stream:get_headers(timeout)
			conn:close()
			return ok, err, errno
		end
		cq:wrap(function()
			s:pause()
			assert.same(ce.ETIMEDOUT, select(3, do_req(0.1)))
			s:resume()
			assert.truthy(do_req())
			s:pause()
			assert.same(ce.ETIMEDOUT, select(3, do_req(0.1)))
			s:resume()
			assert.truthy(do_req())
			s:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("shouldn't throw an error calling :listen() after :close()", function()
		local s = assert(http_server.listen {
			host = "localhost";
			port = 0;
			onstream = function() end;
		})
		s:close()
		s:listen()
	end)
	it("shouldn't throw an error calling :localname() after :close()", function()
		local s = assert(http_server.listen {
			host = "localhost";
			port = 0;
			onstream = function() end;
		})
		s:close()
		s:localname()
	end)
end)
