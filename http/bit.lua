--[[ This module smooths over all the various lua bit libraries

The bit operations are only done
  - on bytes (8 bits),
  - with quantities <= LONG_MAX (0x7fffffff)
  - band with 0x80000000 that is subsequently compared with 0
This means we can ignore the differences between bit libraries.
]]

-- Lua 5.1 didn't have `load` or bitwise operators, just let it fall through.
if _VERSION ~= "Lua 5.1" then
    -- Lua 5.3+ has built-in bit operators, wrap them in a function.
	-- Use debug.getinfo to get correct file+line numbers for loaded snippet
	local info = debug.getinfo(1, "Sl")
	local has_bitwise, bitwise = pcall(load(("\n"):rep(info.currentline+1)..[[return {
		band = function(a, b) return a & b end;
		bor = function(a, b) return a | b end;
		bxor = function(a, b) return a ~ b end;
	}]], info.source))
	if has_bitwise then
		return bitwise
	end
end

-- The "bit" library that comes with luajit
-- also available for lua 5.1 as "luabitop": http://bitop.luajit.org/
local has_bit, bit = pcall(require, "bit")
if has_bit then
	return {
		band = bit.band;
		bor = bit.bor;
		bxor = bit.bxor;
	}
end

-- The "bit32" library shipped with lua 5.2
local has_bit32, bit32 = pcall(require, "bit32")
if has_bit32 then
	return {
		band = bit32.band;
		bor = bit32.bor;
		bxor = bit32.bxor;
	}
end

error("Please install a bit library")
