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
	end)
	it("decompresses over multiple sections", function()
		-- for whatever reason for certain input streams, zlib will not consume it in one go
		local decompressor = http_zlib.inflate()
		decompressor("\31\139\8\0\0\0\0\0\0\3\237\93\235\142\35\199\117\254\61"
			.. "\122\138\50\39\22\103\34\178\73\206\117\119\110\182\44\217\177"
			.. "\16\43\82\188\107\27\182\32\44\154\205\34\217\59\205\110\170\47"
			.. "\195\161\101\1\190\4\200\15\7\206\143\188\72\18\196\129\99\195"
			.. "\242\43\204\190\66\158\36\223\57\167\170\187\154\108\114\102"
			.. "\163\93\95\96\105\177\34\217\93\85\231\212\185\87\157\170\179\23"
			, false)
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
