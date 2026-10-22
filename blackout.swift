// blackout: яскравість 0 + чорне вікно на всі екрани; будь-яка клавіша, рух чи клік миші повертають все назад.
// Дисплей не засинає, тож сесія не блокується і VPN не рветься.
// Активність визначається за системним лічильником простою HID (HIDIdleTime), а не за подіями вікна:
// вікно може втратити фокус (сповіщення, інший застосунок, заставка), і тоді клавіші до нього не доходять.
import AppKit
import IOKit
import IOKit.pwr_mgt

typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (UInt32, Float) -> Int32
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let getB = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
let setB = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

var saved: [UInt32: Float] = [:]
for screen in NSScreen.screens {
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
    var b: Float = 0
    if getB?(id, &b) == 0 { saved[id] = b }
}

func restore() -> Never {
    for (id, b) in saved { _ = setB?(id, b) }
    NSCursor.unhide()
    exit(0)
}
signal(SIGINT) { _ in restore() }
signal(SIGTERM) { _ in restore() }
signal(SIGHUP) { _ in restore() }

// Секунди від останньої дії користувача (клавіатура, миша, трекпад) за даними IOHIDSystem.
func hidIdleSeconds() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return nil }
    return value.doubleValue / 1_000_000_000
}

var assertion: IOPMAssertionID = 0
IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn), "blackout" as CFString, &assertion)

// Блокування екрана чи запуск заставки: повернути яскравість, щоб було видно поле пароля.
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

// Пів секунди паузи, щоб відпускання Enter після запуску команди не повернуло екран одразу.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    for id in saved.keys { _ = setB?(id, 0) }
    var last = hidIdleSeconds() ?? 0
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        guard let idle = hidIdleSeconds() else { return }
        if idle < last { restore() }  // лічильник простою скинувся — була дія користувача
        last = idle
    }
}
app.run()
