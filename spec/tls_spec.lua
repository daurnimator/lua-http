describe("http.tls module", function()
	local tls = require "http.tls"
	it("can create a new client context", function()
		tls.new_client_context()
	end)
	it("can create a new server context", function()
		tls.new_server_context()
	end)
end)
