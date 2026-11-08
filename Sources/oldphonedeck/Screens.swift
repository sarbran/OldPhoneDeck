import AppKit

/// "Screens off" toggle: dims the MacBook's built-in display to zero and puts every display
/// to sleep (this turns the external monitor off). The Mac itself keeps running, so the
/// phone link, Claude and everything else stay reachable. Toggling again wakes the displays
/// and restores the previous brightness.
enum Screens {
    private static let lock = NSLock()
    private static var dark = false

    /// Brightness before dimming is also written to disk, so it can be restored
    /// if oldphonedeck is restarted while the screens are dark.
    private static let stateFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".oldphonedeck/brightness-before-dark")

    static var isDark: Bool { lock.lock(); defer { lock.unlock() }; return dark }

    // MARK: Brightness (private DisplayServices framework; works on Apple Silicon and Intel)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func brightness() -> Float? {
        guard let id = builtInDisplay, let get = symbol("DisplayServicesGetBrightness", as: GetBrightness.self) else { return nil }
        var value: Float = 0
        return get(id, &value) == 0 ? value : nil
    }

    private static func setBrightness(_ value: Float) {
        guard let id = builtInDisplay, let set = symbol("DisplayServicesSetBrightness", as: SetBrightness.self) else {
            print("Could not change the built-in display's brightness")
            return
        }
        _ = set(id, max(0, min(1, value)))
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { print("Could not run \(path): \(error)") }
    }

    // MARK: Toggle

    /// Flips the state and returns the new one (true = screens are now off).
    @discardableResult
    static func toggle() -> Bool {
        lock.lock()
        let goingDark = !dark
        dark = goingDark
        lock.unlock()
        if goingDark { turnOff() } else { turnOn() }
        return goingDark
    }

    private static func turnOff() {
        if let current = brightness() {
            // Never overwrite a good saved value with 0 (e.g. after a double tap).
            if current > 0.02 || !FileManager.default.fileExists(atPath: stateFile.path) {
                try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? String(current).write(to: stateFile, atomically: true, encoding: .utf8)
            }
            setBrightness(0)
        }
        // Sleeps all displays (the external monitor included). The Mac stays awake.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    private static func turnOn() {
        // `caffeinate -u` declares user activity, which wakes the displays. It exits by itself.
        run("/usr/bin/caffeinate", ["-u", "-t", "5"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { restoreBrightness() }
    }

    private static func restoreBrightness() {
        // Only restore a value we saved ourselves; otherwise leave the brightness alone.
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8),
              let saved = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        setBrightness(saved)
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// Called at startup: if the app was closed while the screens were dark, give the
    /// built-in display its brightness back instead of leaving it black.
    static func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        restoreBrightness()
    }
}
