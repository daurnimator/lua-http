local TEST_TIMEOUT = 2
describe("http.server module", function()
	local server = require "http.server"
	local client = require "http.client"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
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
			s:shutdown()
		end)
		cq:wrap(function()
			s:run(on_stream)
			s:close()
		end)
		cq:wrap(function()
			local options = {}
			if path then
				options.path = path
			else
				options.host = host
				options.port = port
			end
			options.tls = tls
			options.version = version
			local conn = client.connect(options)
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
	it("works with plain http 1.1 using UNIX socket domain", function()
		local path = os.tmpname() .. ".socket"
		simple_test(false, 1.1, os.tmpname() .. ".socket")
		finally(function()
			os.remove(path)
		end)
	end)
	pending("works with https 1.1 using UNIX socket domain", function()
		local path = os.tmpname() .. ".socket"
		simple_test(true, 1.1, os.tmpname() .. ".socket")
		finally(function()
			os.remove(path)
		end)
	end)
	it("works with plain http 2.0 using UNIX socket domain", function()
		local path = os.tmpname() .. ".socket"
		simple_test(false, 2.0, os.tmpname() .. ".socket")
		finally(function()
			os.remove(path)
		end)
	end); -- change first pending to 'it' when added ctx generation
	(require "http.tls".has_alpn and pending or pending)("works with https 2.0 using UNIX socket domain", function()
		local path = os.tmpname() .. ".socket"
		simple_test(true, 2.0, os.tmpname() .. ".socket")
		finally(function()
			os.remove(path)
		end)
	end)
end)
