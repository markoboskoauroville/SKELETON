// App.swift: the app, its window (a standard NSWindow), the one title, the menu.
import AppKit

let VERSION = 10
let APP_NAME = "Skeleton (Mantra)"

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var main: MainView!

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
        if UserDefaults.standard.object(forKey: "NSWindow Frame SkeletonMain") == nil { w.center() }
        window = w
        enforceOneTitle()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.enforceOneTitle() }
        Updater.checkAtStart()
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
