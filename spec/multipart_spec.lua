describe("multipart/form_data", function()
	local http_util = require "http.util"
	it("multipart_encode", function()
		local body = http_util.multipart_encode(http_util.generate_boundary(), coroutine.wrap(function()
			local http_headers = require "http.headers"
			do
				local h = http_headers.new()
				h:append("content-type", "text/plain")
				coroutine.yield(h, "foo")
			end
			do
				local boundary = http_util.generate_boundary()
				local h = http_headers.new()
				h:upsert("content-type", "multipart/form-data; boundary=" .. boundary)
				local b = http_util.multipart_encode(boundary, coroutine.wrap(function()
					local child = http_headers.new()
					child:append("content-type", "application/json")
					coroutine.yield(child, "{}")
				end))
				coroutine.yield(h, b)
			end
			do
				local h = http_headers.new()
				h:append("content-type", "application/octet-stream")
				local fh = assert(io.open("README.md"))
				coroutine.yield(h, fh)
				fh:close()
			end
		end))
		for data in body do io.write(data) end
	end)
end)
