describe("http.server module", function()
	local server = require "http.server"
	local client = require "http.client"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local function assert_loop(cq, timeout)
		local ok, err, _, thd = cq:loop(timeout)
		if not ok then
			if thd then
				err = debug.traceback(thd, err)
			end
			error(err, 2)
		end
	end
	local function simple_test(tls, version, path)
		local cq = cqueues.new()
		local options = {}
		if path then
			options.path = path
		else
			options.host = "localhost"
			options.port = 0
		end
		options.version = version
		options.tls = tls
		local s = server.listen(options)
		assert(s:listen())
		local host, port
		if not path then
			local _
			_, host, port = s:localname()
		end
		local on_stream = spy.new(function(stream)
			stream:get_headers()
			stream:shutdown()
			s:pause()
		end)
		cq:wrap(function()
			s:run(on_stream)
			s:close()
		end)
		cq:wrap(function()
			local client_options = {}
			if path then
				client_options.path = path
			else
				client_options.host = host
				client_options.port = port
			end
			client_options.tls = tls
			client_options.version = version
			local conn = client.connect(client_options)
			local stream = conn:new_stream()
			local headers = new_headers()
			headers:append(":method", "GET")
			headers:append(":path", "/")
			headers:append(":scheme", "http")
			assert(stream:write_headers(headers, true))
			stream:get_headers()
			conn:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.spy(on_stream).was.called()
	end
	it("works with plain http 1.1 using IP", function()
		simple_test(false, 1.1)
	end)
	it("works with https 1.1 using IP", function()
		simple_test(true, 1.1)
	end)
	it("works with plain http 2.0 using IP", function()
		simple_test(false, 2.0)
	end);
	(require "http.tls".has_alpn and it or pending)("works with https 2.0 using IP", function()
		simple_test(true, 2.0)
	end)
	it("taking socket from underlying connection is handled well by server", function()
		local cq = cqueues.new()
		local s = server.listen {
			host = "localhost";
			port = 0;
		}
		assert(s:listen())
		local _, host, port = s:localname()
		local on_stream = spy.new(function(stream)
			local sock = stream.connection:take_socket()
			s:pause()
			assert.same("test", sock:read("*a"))
			sock:close()
		end)
		cq:wrap(function()
			s:run(on_stream)
			s:close()
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
		assert.spy(on_stream).was.called()
	end)
	--[[
	--
	-- Until there is a way to generate OpenSSL contexts in this file for
	-- UNIX domain sockets, there is no way to use TLS with this. Because
	-- of this, the status for using TLS with UNIX domain sockets is
	-- pending.
	--
	--]]
	local socket_path = os.tmpname()
	os.remove(socket_path) -- in case it was generated automatically
	it("works with plain http 1.1 using UNIX socket domain", function()
		simple_test(false, 1.1, socket_path)
		finally(function()
			os.remove(socket_path)
		end)
	end)
	pending("works with https 1.1 using UNIX socket domain", function()
		simple_test(true, 1.1, socket_path)
		finally(function()
			os.remove(socket_path)
		end)
	end)
	it("works with plain http 2.0 using UNIX socket domain", function()
		simple_test(false, 2.0, socket_path)
		finally(function()
			os.remove(socket_path)
		end)
	end);
	pending("works with https 2.0 using UNIX socket domain", function()
		simple_test(true, 2.0, socket_path)
		finally(function()
			os.remove(socket_path)
		end)
	end)
end)
