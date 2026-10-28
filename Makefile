PREFIX ?= $(HOME)/.local
AGENT := $(HOME)/Library/LaunchAgents/com.alexandr-kravchuk.blackout.plist

blackout: blackout.swift CGVirtualDisplay.h
	swiftc -O -import-objc-header CGVirtualDisplay.h -o $@ blackout.swift

install: blackout
	install -d $(PREFIX)/bin
	install -m 755 blackout $(PREFIX)/bin/blackout

# Іконка в панелі меню і ⌃⌥⌘B: LaunchAgent запускає `blackout --menubar` при вході в систему.
install-menubar: install
	install -d $(dir $(AGENT))
	sed 's|@BIN@|$(PREFIX)/bin/blackout|' blackout.plist.in > $(AGENT)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall-menubar:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

clean:
	rm -f blackout

.PHONY: install install-menubar uninstall-menubar clean
