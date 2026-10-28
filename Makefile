PREFIX ?= $(HOME)/.local

blackout: blackout.swift CGVirtualDisplay.h
	swiftc -O -import-objc-header CGVirtualDisplay.h -o $@ blackout.swift

install: blackout
	install -d $(PREFIX)/bin
	install -m 755 blackout $(PREFIX)/bin/blackout

clean:
	rm -f blackout

.PHONY: install clean
