describe("http.proxies module", function()
	local http_proxies = require "http.proxies"

	it("read_proxy_vars works", function()
		local proxies = http_proxies.read_proxy_vars(function(k) return ({
			http_proxy = "http://http.proxy";
			https_proxy = "http://https.proxy";
			all_proxy = "http://all.proxy";
			no_proxy = "*";
		})[k] end)
		assert.same({
			http_proxy = "http://http.proxy";
			https_proxy = "http://https.proxy";
			all_proxy = "http://all.proxy";
			no_proxy = "*";
		}, proxies)
		-- Should return nil due to no_proxy being *
		assert.same(nil, proxies:choose("http", "myhost"))
		assert.same(nil, proxies:choose("https", "myhost"))
		assert.same(nil, proxies:choose("other", "myhost"))
		proxies.no_proxy = nil
		assert.same("http://http.proxy", proxies:choose("http", "myhost"))
		assert.same("http://https.proxy", proxies:choose("https", "myhost"))
		assert.same("http://all.proxy", proxies:choose("other", "myhost"))
		proxies.no_proxy = "foo,bar.com,.extra.dot.com"
		assert.same("http://http.proxy", proxies:choose("http", "myhost"))
		assert.same(nil, proxies:choose("http", "foo"))
		assert.same(nil, proxies:choose("http", "bar.com"))
		assert.same(nil, proxies:choose("http", "subdomain.bar.com"))
		assert.same(nil, proxies:choose("http", "sub.sub.subdomain.bar.com"))
		assert.same(nil, proxies:choose("http", "someting.foo"))
		assert.same("http://http.proxy", proxies:choose("http", "else.com"))
		assert.same(nil, proxies:choose("http", "more.extra.dot.com"))
		assert.same(nil, proxies:choose("http", "extra.dot.com"))
		assert.same("http://http.proxy", proxies:choose("http", "dot.com"))
	end)
	it("read_proxy_vars isn't vulnerable to httpoxy", function()
		assert.same({}, http_proxies.read_proxy_vars(function(k) return ({
			GATEWAY_INTERFACE = "CGI/1.1";
			http_proxy = "vulnerable to httpoxy";
		})[k] end))
	end)
end)
