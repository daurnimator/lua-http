package = "http"
version = "scm-0"

description = {
	summary = "HTTP library for Lua";
	license = "MIT/X11";
}

source = {
	url = "git+https://github.com/daurnimator/lua-http.git";
}

dependencies = {
	"lua >= 5.1";
	"compat53"; -- Only if lua < 5.3
	"bit32"; -- Only if lua == 5.1
	"cqueues";
	"luaossl >= 20150305";
}

build = {
	type = "builtin";
	modules = {
		["http.bit"] = "http/bit.lua";
		["http.hpack"] = "http/hpack.lua";
	};
}
