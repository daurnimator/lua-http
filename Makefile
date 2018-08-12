INTERFACES = \
	connection.md \
	stream.md

MODULES = \
	http.bit.md \
	http.client.md \
	http.cookie.md \
	http.h1_connection.md \
	http.h1_reason_phrases.md \
	http.h1_stream.md \
	http.h2_connection.md \
	http.h2_error.md \
	http.h2_stream.md \
	http.headers.md \
	http.hpack.md \
	http.hsts.md \
	http.proxies.md \
	http.request.md \
	http.server.md \
	http.socks.md \
	http.tls.md \
	http.util.md \
	http.version.md \
	http.websocket.md \
	http.zlib.md \
	http.compat.prosody.md \
	http.compat.socket.md

FILES = \
	introduction.md \
	interfaces.md \
	$(addprefix interfaces/,$(INTERFACES)) \
	modules.md \
	$(addprefix modules/,$(MODULES)) \
	links.md

all: lua-http.html lua-http.pdf lua-http.3

lua-http.html: template.html site.css metadata.yaml $(FILES)
	pandoc -o $@ -t html5 -s --toc --template=template.html --section-divs --self-contained -c site.css metadata.yaml $(FILES)

lua-http.pdf: metadata.yaml $(FILES)
	pandoc -o $@ -t latex -s --toc --toc-depth=2 -V documentclass=article -V classoption=oneside -V links-as-notes -V geometry=a4paper,includeheadfoot,margin=2.54cm metadata.yaml $(FILES)

lua-http.3: metadata.yaml $(FILES)
	pandoc -o $@ -t man -s metadata.yaml $(FILES)

man: lua-http.3
	man -l $^

clean:
	rm -f lua-http.html lua-http.pdf lua-http.3

.PHONY: all man install clean
