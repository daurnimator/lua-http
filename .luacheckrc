std = "min"
files["spec"] = {
	std = "+busted";
	new_globals = {
		"TEST_TIMEOUT";
		"assert_loop";
	};
}
max_line_length = false
