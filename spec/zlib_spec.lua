local ok, http_zlib = pcall(require, "http.zlib");
(ok and describe or pending)("zlib compat layer", function()
	it("round trips", function()
		local function test(str)
			local compressor = http_zlib.deflate()
			local decompressor = http_zlib.inflate()
			local z = compressor(str, true)
			assert.same(str, decompressor(z, true))
		end
		test "foo"
		test "hi"
		test(("az"):rep(100000))
	end)
	it("streaming round trips", function()
		local function test(...)
			local compressor = http_zlib.deflate()
			local decompressor = http_zlib.inflate()
			local t = {...}
			local out = {}
			for i=1, #t do
				local z = compressor(t[i], false)
				out[i] = decompressor(z, false) or ""
			end
			out[#t+1] = decompressor(compressor("", true), true)
			assert.same(table.concat(t), table.concat(out))
		end

		test(
			"short string",
			("foo"):rep(100000),
			"middle",
			("bar"):rep(100000),
			"end"
		)
	end)
	it("decompressor errors on invalid input", function()
		local decompressor = http_zlib.inflate()
		assert.has.errors(function() decompressor("asdfghjk", false) end)
	end);
	-- lzlib doesn't report a missing end of string in inflate
	(http_zlib.engine == "lzlib" and pending or it)("decompressor fails on incorrect end_stream flag", function()
		local compressor = http_zlib.deflate()
		local decompressor = http_zlib.inflate()
		local z = compressor(("foo"):rep(100000), false)
		assert(#z > 0)
		assert.has.errors(function() decompressor(z, true) end)
	end)
end)
