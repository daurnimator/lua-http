TEST_TIMEOUT = 10

function assert_loop(cq, timeout)
	local ok, err, _, thd = cq:loop(timeout)
	if not ok then
		if thd then
			err = debug.traceback(thd, err)
		end
		error(err, 2)
	end
end

-- Solves https://github.com/keplerproject/luacov/issues/38
local cqueues = require "cqueues"
local has_luacov, luacov_runner = pcall(require, "luacov.runner")
if has_luacov then
	local wrap; wrap = cqueues.interpose("wrap", function(self, func, ...)
		func = luacov_runner.with_luacov(func)
		return wrap(self, func, ...)
	end)
end

-- Allow tests to pick up configured locale
local locale = os.getenv("LOCALE")
if locale then
	os.setlocale(locale)
	if locale ~= os.setlocale(locale) then
		print("Locale " .. locale .. " is not available.")
		os.exit(1) -- busted doesn't fail if helper script throws errors: https://github.com/Olivine-Labs/busted/issues/549
	end
end
