-- Solves https://github.com/keplerproject/luacov/issues/38
local cqueues = require "cqueues"
local luacov_runner = require "luacov.runner"
local wrap; wrap = cqueues.interpose("wrap", function(self, func, ...)
	func = luacov_runner.with_luacov(func)
	return wrap(self, func, ...)
end)
