describe("http.cookies moudle", function()
	local cookies, time
	setup(function()
		cookies = require "http.cookies"
		time = os.time()
	end)

	it("Set-Cookie headers can be properly parsed", function()
		local host, path = "example.com", "/"
		local expected = {
			last_access = time,
			path = "/",
			secure = true,
			value = "a3fWa",
			expires = time + 10000,
			domain = "example.com",
			host_only = false,
			persistent = true,
			key = "id",
			http_only = true,
			creation = time
		}
		local line = "id=a3fWa; Max-Age=10000; Secure; HttpOnly"
		assert.same(expected, cookies.parse_set_cookie(line, host, path, time))
		expected = {
			last_access = time,
			path = "/random/path",
			secure = false,
			value = "potatocakes",
			domain = "test.domain.example.com",
			host_only = true,
			persistent = false,
			key = "name",
			http_only = false,
			creation = time
		}
		line = "name=potatocakes; Domain=test.domain.example.com; " ..
			"Path=/random/path"
		assert.same(expected, cookies.parse_set_cookie(line, host, path, time))
	end)

	it("Set-Cookie headers are properly created", function()
		local line = "id=a3fWa; Max-Age=10000; Secure; HttpOnly"
		assert.same(line, cookies.bake_cookie{
			max_age = 10000;
			secure = true;
			http_only = true;
			key = "id";
			value = "a3fWa";
		})
		line = "name=potatocakes; Domain=test.domain.example.com; " ..
			"Path=/random/path"
		assert.same(line, cookies.bake_cookie{
			domain = "test.domain.example.com";
			path = "/random/path";
			key = "name";
			value = "potatocakes";
		})
	end)

	it("Cookies from the `Cookie` header are iterable", function()
		local test_cookies = {
			key1 = "value1";
			key2 = "value2";
		}
		local cookie_string = "key1=value1; key2=value2"
		for key, value in pairs(cookies.match_cookies(cookie_string)) do
			assert.same(test_cookies[key], value)
		end
	end)

	it("`Cookie` header can be converted to a table", function()
		assert.same({{"key1", "value1"}, {"key2", "value2"},
			key1 = "value1";
			key2 = "value2";
		}, cookies.parse_cookies("key1=value1; key2=value2"))
	end)
	describe("cookiejar", function()
		local new_cookies
		before_each(function()
			new_cookies = {
				{
					last_access = time;
					path = "/random/path";
					secure = false;
					value = "potatocakes";
					domain = "test.domain.example.com";
					host_only = true;
					persistent = true;
					key = "name";
					http_only = false;
					creation = time;
					expires = time + 30;
				};
				{
					last_access = time + 3;
					path = "/whatever";
					secure = true;
					value = "example_value";
					domain = "potato.com";
					host_only = false;
					persistent = false;
					key = "nonpersistent";
					http_only = false;
					creation = time + 3;
					expires = math.huge;
				};
				{
					last_access = time + 5;
					path = "/random/path_two";
					secure = true;
					value = "this_is_an_example";
					domain = "test.domain.example.com";
					host_only = false;
					persistent = true;
					key = "key";
					http_only = true;
					creation = time + 5;
					expires = time + 100;
				};
			}
		end)
		after_each(function()
			new_cookies = nil
		end)

		it("New values can be created without duplication", function()
			-- check that cookies are sorted in-order by expiration date by
			-- adding them in at random expirations, as well as adding in a
			-- non-persistent key which has the lowest priority of removal
			local jar = cookies.cookiejar.new()
			jar:add(new_cookies[1])
			jar:add(new_cookies[2]) -- not persistent, will be moved to front
			jar:add(new_cookies[3]) -- expires last, moved @ front of persists
			jar:add(new_cookies[3]) -- will not be duplicated
			assert.same({
				["test.domain.example.com"] = {
					["/random/path"] = {
						["name"] = new_cookies[1];
					};
					["/random/path_two"] = {
						["key"] = new_cookies[3];
					};
				};
				["potato.com"] = {
					["/whatever"] = {
						["nonpersistent"] = new_cookies[2];
					}
				};
				new_cookies[2];
				new_cookies[3];
				new_cookies[1];
			}, jar.cookies)
		end)

		it("Expired cookies are removed", function()
			-- manually set cookie to expire
			local jar = cookies.cookiejar.new()
			jar:add(new_cookies[1]) -- has expiration date
			new_cookies[3].expires = time - 5 -- expire before "now"
			jar:add(new_cookies[3]) -- has expiration date
			assert.same({
				["test.domain.example.com"] = {
					["/random/path"] = {
						["name"] = new_cookies[1];
					};
					["/random/path_two"] = {
						["key"] = new_cookies[3];
					};
				};
				new_cookies[1];
				new_cookies[3];
			}, jar.cookies)
			jar:remove_expired(time)
			assert.same({
				["test.domain.example.com"] = {
					["/random/path"] = {
						["name"] = new_cookies[1];
					};
				};
				new_cookies[1];
			}, jar.cookies)
			new_cookies[1].expires = time - 5
			jar:remove_expired(time)
			assert.same({}, jar.cookies)
		end)

		it("Cookies can be trimmed to a certain count", function()
			local jar = cookies.cookiejar.new()
			jar:add(new_cookies[1])
			jar:add(new_cookies[2])
			jar:add(new_cookies[3])
			jar:trim(1)
			assert.same({
				["potato.com"] = {
					["/whatever"] = {
						["nonpersistent"] = new_cookies[2];
					}
				};
				new_cookies[2]; -- the not-persistent cookie
			}, jar.cookies)
		end)

		it("Cookies can be serialized, based on parameters", function()
			local jar = cookies.cookiejar.new()
			jar:add(new_cookies[1])
			jar:add(new_cookies[2])
			jar:add(new_cookies[3])
			assert.same("key=this_is_an_example; name=potatocakes",
				jar:serialize_cookies_for("test.domain.example.com",
					"/random", true))
		end)
	end)
end)
