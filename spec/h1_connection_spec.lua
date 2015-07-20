describe("http 1 connections", function()
	local h1_connection = require "http.h1_connection"
	local cs = require "cqueues.socket"
	local function new_pair(version)
		local s, c = cs.pair()
		s = h1_connection.new(s, version)
		c = h1_connection.new(c, version)
		return s, c
	end
	it("request line should round trip", function()
		local function test(req_method, req_path, req_version)
			local s, c = new_pair(req_version)
			assert(c:write_request_line(req_method, req_path, req_version))
			assert(c:flush())
			local res_method, res_path, res_version = assert(s:read_request_line())
			assert.same(req_method, res_method)
			assert.same(req_path, res_path)
			assert.same(req_version, res_version)
		end
		test("GET", "/", 1.1)
		test("POST", "/foo", 1.0)
		test("OPTIONS", "*", 1.1)
	end)
	it(":write_request_line parameters should be validated", function()
		assert.has.errors(function() new_pair(1.1):write_request_line("", "/foo", 1.0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "", 1.0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "/", 0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "/", 2) end)
	end)
	it(":read_request_line should throw on invalid request", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:write(chunk, "\r\n"))
			assert(s:flush())
			assert.has.errors(function() c:read_request_line() end)
		end
		test("invalid request line")
		test(" / HTTP/1.1")
		test("HTTP/1.1")
		test("GET HTTP/1.0")
		test("GET  HTTP/1.0")
		test("GET HTTP/1.0")
		test("GET HTTP/1.0")
		test("GET / HTP/1.1")
		test("GET / HTTP 1.1")
		test("GET / HTTP/1")
		test("GET / HTTP/2.0")
		test("GET / HTTP/1.1\nHeader: value") -- missing \r
	end)
	it("headers should round trip", function()
		local function test(input)
			local s, c = new_pair(1.1)

			assert(c:write_request_line("GET", "/", 1.1))
			for _, t in ipairs(input) do
				assert(c:write_header(t[1], t[2]))
			end
			assert(c:write_headers_done())

			assert(s:read_request_line())
			for _, t in ipairs(input) do
				local k, v = assert(s:read_header())
				assert.same(t[1], k)
				assert.same(t[2], v)
			end
			assert(s:read_headers_done())
		end
		test{}
		test{
			{"foo", "bar"};
		}
		test{
			{"Host", "example.com"};
			{"User-Agent", "some user/agent"};
			{"Accept", "*/*"};
		}
	end)
	it("chunks round trip", function()
		local s, c = new_pair(1.1)
		assert(c:write_request_line("POST", "/", 1.1))
		assert(c:write_header("Transfer-Encoding", "chunked"))
		assert(c:write_headers_done())
		assert(c:write_body_chunk("this is a chunk"))
		assert(c:write_body_chunk("this is another chunk"))
		assert(c:write_body_last_chunk())
		assert(c:write_headers_done())

		assert(s:read_request_line())
		assert(s:read_header())
		assert(s:read_headers_done())
		assert.same("this is a chunk", s:read_body_chunk())
		assert.same("this is another chunk", s:read_body_chunk())
		assert.same(nil, s:read_body_chunk())
		assert(s:read_headers_done())
	end)
end)
