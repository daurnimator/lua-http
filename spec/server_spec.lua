describe("http.server module", function()
	local server = require "http.server"
	local client = require "http.client"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local function simple_test(family, tls, version)
		local cq = cqueues.new()
		local options = {
			family = family;
			tls = tls;
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
		local on_stream = spy.new(function(s, stream)
			stream:get_headers()
			stream:shutdown()
			s:close()
		end)
		options.on_stream = on_stream
		local s = server.listen(options)
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
				version = version;
			}
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
		simple_test(cs.AF_INET, false, 1.1)
	end)
	it("works with https 1.1 using IP", function()
		simple_test(cs.AF_INET, true, 1.1)
	end)
	it("works with plain http 2.0 using IP", function()
		simple_test(cs.AF_INET, false, 2.0)
	end);
	(require "http.tls".has_alpn and it or pending)("works with https 2.0 using IP", function()
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
	it("taking socket from underlying connection is handled well by server", function()
		local cq = cqueues.new()
		local on_stream = spy.new(function(s, stream)
			local sock = stream.connection:take_socket()
			s:close()
			assert.same("test", sock:read("*a"))
			sock:close()
		end);
		local s = server.listen {
			host = "localhost";
			port = 0;
			on_stream = on_stream;
		}
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
		assert.spy(on_stream).was.called()
	end)
end)
