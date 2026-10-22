PREFIX ?= $(HOME)/.local

blackout: blackout.swift
	swiftc -O -o $@ $<

install: blackout
	install -d $(PREFIX)/bin
	install -m 755 blackout $(PREFIX)/bin/blackout

clean:
	rm -f blackout

.PHONY: install clean
