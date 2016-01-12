describe("http.client module", function()
	local client = require "http.client"
	it("invalid network parameters return nil, err, errno", function()
		-- Invalid network parameters will return nil, err, errno
		local ok, err, errno = client.connect{host="127.0.0.1", port="invalid"}
		assert.same(nil, ok)
		assert.same("string", type(err))
		assert.same("number", type(errno))
	end)
end)
