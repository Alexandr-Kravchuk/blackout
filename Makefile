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

# Кнопка для Control Center: Shortcut «Blackout» виконує `blackout --trigger`.
# Shortcuts спитає підтвердження імпорту; потрібне Settings → Advanced → Allow Running Scripts.
install-shortcut: Blackout.shortcut.plist
	plutil -convert binary1 -o $(TMPDIR)blackout-unsigned.shortcut Blackout.shortcut.plist
	shortcuts sign --mode anyone --input $(TMPDIR)blackout-unsigned.shortcut --output $(TMPDIR)Blackout.shortcut
	open $(TMPDIR)Blackout.shortcut

uninstall-menubar:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

clean:
	rm -f blackout

.PHONY: install install-menubar install-shortcut uninstall-menubar clean
