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
	"bitop"; -- Only if lua == 5.1
}

build = {
	type = "builtin";
	modules = {
		["http.hpack"] = "http/hpack.lua";
	};
}
