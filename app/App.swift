// App.swift: the app, its window (a standard NSWindow), the one title, the menu.
import AppKit

let VERSION = 15
let APP_NAME = "Skeleton (Mantra)"

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var main: MainView!
    var placedAt = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = APP_NAME
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentMinSize = NSSize(width: 920, height: 560)
        w.delegate = self
        main = MainView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--camera"), i + 1 < args.count { main.pendingCamera = args[i + 1]; main.reloadDevices() }
        if let i = args.firstIndex(of: "--cameras"), i + 1 < args.count {
            let names = args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let n = max(1, min(4, names.count))
            main.pendingCams = names
            UserDefaults.standard.set(n, forKey: "camcount")
            main.camSeg.selectedSegment = n - 1
            main.setCameraCount(n)
        }
        w.contentView = main
        w.setFrameAutosaveName("SkeletonMain")
        placeOnBuiltInScreen(w)
        window = w
        enforceOneTitle()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.enforceOneTitle() }
        Updater.checkAtStart()
    }

    // MARK: the window opens on the MacBook Pro's own screen (never the BenQ), unless Marko moved it himself

    static func builtInScreen() -> NSScreen? {
        if let s = NSScreen.screens.first(where: { $0.localizedName.contains("Built-in") }) { return s }
        return NSScreen.screens.first { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// First launch, or the saved frame is on a screen that is gone or is not the built-in one and Marko did not choose it:
    /// put the window on the built-in screen. Once he drags it to another screen himself, that choice is kept (frame autosave).
    func placeOnBuiltInScreen(_ w: NSWindow) {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "NSWindow Frame SkeletonMain") != nil
        guard let builtIn = AppDelegate.builtInScreen() else { if !saved { w.center() }; return }
        let chosen = d.bool(forKey: "window.screenChosen")
        let onBuiltIn = w.screen == builtIn
        if !saved || (!chosen && !onBuiltIn) {
            let vis = builtIn.visibleFrame
            var size = saved ? w.frame.size : NSSize(width: 1100, height: 720)
            size.width = min(size.width, vis.width); size.height = min(size.height, vis.height)
            w.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        placedAt = Date()
    }

    /// A move to another screen later than 3 s after launch is his choice: remembered, never overridden.
    func windowDidMove(_ n: Notification) {
        guard let w = window, Date().timeIntervalSince(placedAt) > 3, let b = AppDelegate.builtInScreen() else { return }
        UserDefaults.standard.set(w.screen != nil && w.screen != b, forKey: "window.screenChosen")
    }

    @objc func renderMannequin() { main.renderSelected(last: true) }

    func buildMenu() {
        let bar = NSMenu(), item = NSMenuItem(), m = NSMenu()
        m.addItem(withTitle: "Quit " + APP_NAME, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = m; bar.addItem(item)
        let rItem = NSMenuItem(), rMenu = NSMenu(title: "Recording")
        let rm = NSMenuItem(title: "Render Mannequin", action: #selector(renderMannequin), keyEquivalent: "m")
        rm.keyEquivalentModifierMask = [.command, .shift]; rm.target = self
        rMenu.addItem(rm); rItem.submenu = rMenu; bar.addItem(rItem)
        NSApp.mainMenu = bar
    }

    /// One title only (MANTRA_MANIFEST modules/one-title-only.md): the system title is never drawn, in any state.
    func enforceOneTitle() {
        guard let w = window else { return }
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        func hide(_ v: NSView) {
            if let t = v as? NSTextField, t.stringValue == APP_NAME { t.isHidden = true }
            v.subviews.forEach(hide)
        }
        if let root = w.contentView?.superview { for v in root.subviews where v !== w.contentView { hide(v) } }
    }

    func windowDidBecomeKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResignKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResize(_ n: Notification) { enforceOneTitle() }
    func windowDidEnterFullScreen(_ n: Notification) { enforceOneTitle() }
    func windowDidExitFullScreen(_ n: Notification) { enforceOneTitle() }

    /// The window's X quits the app (no-on-off-button.md).
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
