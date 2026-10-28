// blackout: гасить усі екрани; будь-яка клавіша, рух чи клік миші повертають все назад.
// Вбудований дисплей: яскравість 0 (підсвітка гасне повністю) + чорне вікно.
// Зовнішній дисплей: soft disconnect через приватний CGSConfigureDisplayEnabled — без сигналу дисплей переходить у standby.
// Яскравість для зовнішнього не підходить: у Studio Display найменше значення через HID — 400 з 60000, підсвітка світить.
// Дисплей не засинає, тож сесія не блокується і VPN не рветься.
// Активність визначається за системним лічильником простою HID (HIDIdleTime), а не за подіями вікна:
// вікно може втратити фокус (сповіщення, інший застосунок, заставка), і тоді клавіші до нього не доходять.
//
// blackout --restore — підключити всі дисплеї, якщо blackout завершився аварійно і зовнішній дисплей лишився вимкненим.
// blackout --menubar — іконка в панелі меню і гаряча клавіша ⌃⌥⌘B; кожне затемнення — окремий процес blackout,
// тож аварія затемнення не зачіпає іконку.
import AppKit
import Carbon
import IOKit
import IOKit.pwr_mgt

typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (UInt32, Float) -> Int32
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let getB = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
let setB = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let setEnabled = dlsym(sl, "CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: EnableFn.self) }
let getAllDisplays = dlsym(sl, "CGSGetDisplayList").map { unsafeBitCast($0, to: ListFn.self) }

func onlineDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

// Усі дисплеї, разом із від'єднаними: CGGetOnlineDisplayList від'єднаних не повертає.
func allDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    guard let getAllDisplays, getAllDisplays(0, nil, &n) == .success, n > 0 else { return onlineDisplays() }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    guard getAllDisplays(n, &ids, &n) == .success else { return onlineDisplays() }
    return Array(ids.prefix(Int(n)))
}

// .forAppOnly: за документацією CGConfigureOption зміна діє, поки працює процес, тож після аварійного
// завершення macOS має сама підключити дисплей. Якщо .forAppOnly не приймається — .forSession.
func configure(_ id: CGDirectDisplayID, enabled: Bool, options: [CGConfigureOption]) -> Bool {
    guard let setEnabled else { return false }
    for option in options {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        guard setEnabled(cfg, id, enabled) == .success else { CGCancelDisplayConfiguration(cfg); return false }
        if CGCompleteDisplayConfiguration(cfg, option) == .success { return true }
    }
    return false
}

// Крутить run loop, доки умова не виконається або не мине час.
@discardableResult
func waitUntil(seconds: Double, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return true
}

if CommandLine.arguments.dropFirst().first == "--restore" {
    for id in allDisplays() { _ = configure(id, enabled: true, options: [.forSession]) }
    exit(0)
}

var child: Process?

// Запускає цей самий файл з аргументами. Друге затемнення, поки працює перше, не запускається.
func runSelf(_ arguments: [String] = []) {
    if arguments.isEmpty, child?.isRunning == true { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    p.arguments = arguments
    try? p.run()
    if arguments.isEmpty { child = p }
}

final class MenuTarget: NSObject {
    @objc func blackout() { runSelf() }
    @objc func restoreDisplays() { runSelf(["--restore"]) }
}

func runMenuBar() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let target = MenuTarget()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "blackout")
    let menu = NSMenu()
    let off = NSMenuItem(title: "Погасити екрани", action: #selector(MenuTarget.blackout), keyEquivalent: "b")
    off.keyEquivalentModifierMask = [.control, .option, .command]
    menu.addItem(off)
    menu.addItem(NSMenuItem(title: "Підключити всі дисплеї", action: #selector(MenuTarget.restoreDisplays), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = target }
    item.menu = menu

    // Carbon RegisterEventHotKey не потребує дозволу Accessibility, на відміну від глобального монітора подій.
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in runSelf(); return noErr }, 1, &spec, nil, nil)
    var hotKey: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey),
        EventHotKeyID(signature: OSType(0x626c6b74), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    if status != noErr {
        // Комбінацію вже зайняв інший застосунок: лишається тільки пункт меню.
        off.keyEquivalent = ""
        FileHandle.standardError.write("blackout: ⌃⌥⌘B зайнята (\(status)), лишається тільки меню\n".data(using: .utf8)!)
    }
    withExtendedLifetime((target, item, hotKey)) { app.run() }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--menubar" { runMenuBar() }

var saved: [UInt32: Float] = [:]
for screen in NSScreen.screens {
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
    var b: Float = 0
    if getB?(id, &b) == 0 { saved[id] = b }
}

var disconnected: [CGDirectDisplayID] = []
var virtualDisplay: CGVirtualDisplay?

func restore() -> Never {
    for id in disconnected { _ = configure(id, enabled: true, options: [.forSession]) }
    // Віртуальний дисплей прибрати лише після того, як фізичний повернувся: інакше на мить не лишиться жодного дисплея.
    if virtualDisplay != nil {
        waitUntil(seconds: 5) { disconnected.allSatisfy { CGDisplayIsActive($0) != 0 } }
        virtualDisplay = nil
    }
    for (id, b) in saved { _ = setB?(id, b) }
    NSCursor.unhide()
    exit(0)
}

// Обробник — через DispatchSource на головній черзі: restore() крутить run loop, у сигнальному обробнику це не можна.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { restore() }
    source.resume()
    signalSources.append(source)
}

// Секунди від останньої дії користувача (клавіатура, миша, трекпад) за даними IOHIDSystem.
func hidIdleSeconds() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return nil }
    return value.doubleValue / 1_000_000_000
}

// Віртуальний дисплей з тим самим режимом, що й у фізичного: вікна, які переїдуть на нього, збережуть розмір.
func makeVirtualDisplay(like id: CGDirectDisplayID) -> CGVirtualDisplay? {
    guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(DispatchQueue.main)
    descriptor.name = "blackout"
    descriptor.maxPixelsWide = UInt32(mode.pixelWidth)
    descriptor.maxPixelsHigh = UInt32(mode.pixelHeight)
    descriptor.sizeInMillimeters = CGDisplayScreenSize(id)
    descriptor.vendorID = 0xb1ac
    descriptor.productID = 1
    descriptor.serialNum = 1
    guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = mode.pixelWidth > mode.width ? 1 : 0
    settings.modes = [CGVirtualDisplayMode(width: UInt32(mode.width), height: UInt32(mode.height), refreshRate: 60)]
    guard display.apply(settings) else { return nil }
    let ready = waitUntil(seconds: 3) { onlineDisplays().contains(display.displayID) }
    return ready ? display : nil
}

// Від'єднати зовнішні дисплеї. Коли кришка закрита, вбудованого дисплея немає, і без жодного дисплея
// macOS може приспати Mac (а сон розриває VPN), тож спершу створюється віртуальний дисплей.
// Не вдалося створити віртуальний або від'єднати — дисплей лишається під яскравістю 0 і чорним вікном.
func disconnectExternalDisplays() {
    let online = onlineDisplays()
    let external = online.filter { CGDisplayIsBuiltin($0) == 0 }
    guard !external.isEmpty, setEnabled != nil else { return }
    if !online.contains(where: { CGDisplayIsBuiltin($0) != 0 }) {
        guard let display = makeVirtualDisplay(like: CGMainDisplayID()) else { return }
        virtualDisplay = display
    }
    for id in external where configure(id, enabled: false, options: [.forAppOnly, .forSession]) {
        disconnected.append(id)
    }
    if disconnected.isEmpty { virtualDisplay = nil }
}

var assertions: [IOPMAssertionID] = []
for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
    var assertion: IOPMAssertionID = 0
    IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "blackout" as CFString, &assertion)
    assertions.append(assertion)
}

// Блокування екрана чи запуск заставки: повернути все, щоб було видно поле пароля.
let dnc = DistributedNotificationCenter.default()
for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
    dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in restore() }
}
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in restore() }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var windows: [NSWindow] = []
for screen in NSScreen.screens {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.backgroundColor = .black
    w.level = .screenSaver
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    w.setFrame(screen.frame, display: true)
    w.orderFrontRegardless()
    windows.append(w)
}
NSCursor.hide()

// Затемнити після пів секунди без дій: інакше відпускання Enter чи гарячої клавіші одразу поверне екран.
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { start in
    guard (hidIdleSeconds() ?? 1) >= 0.5 else { return }
    start.invalidate()
    disconnectExternalDisplays()
    for id in saved.keys where !disconnected.contains(id) { _ = setB?(id, 0) }
    var last = hidIdleSeconds() ?? 0
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        guard let idle = hidIdleSeconds() else { return }
        if idle < last { restore() }  // лічильник простою скинувся — була дія користувача
        last = idle
    }
}
app.run()
