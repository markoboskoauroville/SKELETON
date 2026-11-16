// PhoneSource.swift: "Manual Camera (<phone>, USB|Wi-Fi)": every phone running Mantra Manual Camera v221+ (the Pixel 7,
// the Nothing A142, ...) as its own FrameSource, several at once (Marko, 16.11.2026: "four cameras connected at the same time").
//
// Marko, 16.11.2026: "if I connect via USB my Pixel phone, this app needs to understand how to adjust the phone and the
// camera to get the best possible picture available on this USB connection ... start the camera itself, adjust the
// settings of this phone and being able to use it for posing."
//
// How: a background scan lists the phones on adb (one entry per hardware serial; USB wins over adb-over-Wi-Fi). On the cable,
// `adb forward tcp:0` puts the camera's Mantra Link (48100) and its status (48102) on free local ports; without one, the
// stream goes straight to the phone's address (its LAN or Tailscale address, whichever answers faster) at a lower bit rate
// (12 Mbit/s: the Pixel's 2.4 GHz Wi-Fi did not carry 40). `am start ... --es mode skeleton` starts the camera with our choices (lens, size, fps,
// bit rate, keyframe every second, 50 Hz anti-banding, stabilisation off, exposure and white balance locked after 3 s),
// MODE 2 asks for the camera's own hardware stream (HEVC or H.264, untouched), VideoToolbox decodes it to BGRA.
// The wire is MANTRA_NDI shared/kotlin/.../Link.kt (type byte, big-endian length, payload; SCONFIG 4, SFRAME 5).
// Times: the stream's pts are the phone's sensor timestamps (elapsedRealtime); the status gives the phone's clock, and an
// NTP-style exchange (the fastest of the last answers) maps it onto the Mac's host clock, so the time handed to the
// pipeline is when the picture was TAKEN, on the same clock as AVCapture's, and the latency is measured, not guessed.
// Over adb on Wi-Fi (no cable) the phone is reached directly at its address: adb's own tunnel is too slow for video
// (MANTRA_VIRTUAL_CAM LESSONS 5).
import Foundation
import Network
import VideoToolbox
import CoreMedia

final class PhoneSource: FrameSource {
    static let package = "com.mantraproductions.manualcamera"
    static let activity = "com.mantraproductions.manualcamera/com.mantraproductions.ndi.MainActivity"
    static let minVersion = 221
    /// --camera pixel / nothing / phone / "manual camera"
    static func matches(_ name: String, _ p: PhoneEntry) -> Bool {
        let n = name.lowercased()
        if n == p.savedID.lowercased() || p.label.lowercased().contains(n) || p.hwSerial.lowercased() == n { return true }
        return (n == "phone" || n == "manual camera") && p.model.lowercased().contains("pixel")
    }

    // MARK: the phones Skeleton can see (scanned in the background: adb is never called on the main thread)

    /// Every phone with Manual Camera on adb, one entry per phone (a phone on USB and Wi-Fi at once is one entry, USB).
    private(set) static var known: [PhoneEntry] = []
    /// The first scan has answered (until then a phone asked for or remembered is waited for, not replaced).
    private(set) static var scannedOnce = false
    private static var scanning = false
    private static var scanTimer: DispatchSourceTimer?
    /// Posted on the main queue when [known] changed.
    static let changed = Notification.Name("PhoneSource.changed")

    /// Starts the scan (every 4 s); the first answer comes within a second or two.
    static func startScanning() {
        guard scanTimer == nil, PhoneAdb.present else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 4)
        t.setEventHandler { scanOnce() }
        t.resume(); scanTimer = t
    }

    /// Marko, 16.11.2026: "If ADB is there and camera not working, it needs to kick it in automatically. In the settings we
    /// can disable automatic kicks ... By default it's enabled." The switch AUTO START PHONE CAMERAS (ADB) writes this.
    /// Off: no adb connect, no camera started or restarted by itself; a phone starts only when chosen (CONNECT).
    static var autoStart: Bool {
        get { UserDefaults.standard.object(forKey: "phone.autostart") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "phone.autostart") }
    }

    /// Marko's phones' wireless adb addresses (the Pixel on Tailscale, the Nothing), and every one seen since.
    static var knownAdbAddresses: [String] {
        get { UserDefaults.standard.stringArray(forKey: "phone.adbAddresses") ?? ["100.70.23.53:5555", "10.239.153.128:5555"] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: "phone.adbAddresses") }
    }
    private static var lastAutoConnect = 0.0

    /// adb connect to the known wireless addresses and to the phones announced by mDNS (wireless debugging), at most every
    /// 20 s. Never touches the phones' networks or tethering.
    private static func autoConnect() {
        let now = Date().timeIntervalSince1970
        guard autoStart, now - lastAutoConnect > 20 else { return }
        lastAutoConnect = now
        let listed = Set(PhoneAdb.devices().map { $0.serial })
        var targets = knownAdbAddresses
        for line in PhoneAdb.run(["mdns", "services"], timeout: 5).split(separator: "\n") where line.contains("_adb-tls-connect") {
            if let hp = line.split(separator: "\t").last.map({ String($0).trimmingCharacters(in: .whitespaces) }), hp.contains(":") { targets.append(hp) }
        }
        for t in Set(targets) where !listed.contains(t) {
            let out = PhoneAdb.run(["connect", t], timeout: 4)
            if out.contains("connected") && !out.contains("cannot") { PhoneLog.line("adb connect \(t): \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    private static func scanOnce() {
        if scanning { return }; scanning = true; defer { scanning = false }
        autoConnect()
        let found = PhoneAdb.phones()
        let wifi = found.compactMap { $0.wifiSerial }
        if !wifi.isEmpty && !Set(wifi).isSubset(of: Set(knownAdbAddresses)) { knownAdbAddresses = knownAdbAddresses + wifi }
        DispatchQueue.main.async {
            let first = !scannedOnce
            scannedOnce = true
            if first || found.map({ $0.key }) != known.map({ $0.key }) { known = found; NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    /// The run's choices (UserDefaults phone.lens / phone.width / phone.fps / phone.mbps / phone.mbps.wifi / phone.codec).
    struct Options {
        var lens = "back_main"      // back_main (1x), back_wide (ultrawide), front, or L1..Ln
        var width = 1920            // 1920 (1080p) or 3840 (4K) or 1280
        var fps = 30
        var mbps = 40               // on the USB cable (measured 16.11.2026: 30 fps, 40 Mbit/s, ~95 ms)
        var mbpsWifi = 12           // over Wi-Fi (the Pixel's 2.4 GHz link: 40 fell to 18-22 fps and 0.5-0.9 s; 12 holds 30 fps, ~125 ms)
        var codec = "hevc"          // hevc or h264
        static func load() -> Options {
            let d = UserDefaults.standard; var o = Options()
            if let v = d.string(forKey: "phone.lens"), !v.isEmpty { o.lens = v }
            if d.integer(forKey: "phone.width") > 0 { o.width = d.integer(forKey: "phone.width") }
            if d.integer(forKey: "phone.fps") > 0 { o.fps = d.integer(forKey: "phone.fps") }
            if d.integer(forKey: "phone.mbps") > 0 { o.mbps = d.integer(forKey: "phone.mbps") }
            if d.integer(forKey: "phone.mbps.wifi") > 0 { o.mbpsWifi = d.integer(forKey: "phone.mbps.wifi") }
            if let v = d.string(forKey: "phone.codec"), !v.isEmpty { o.codec = v }
            return o
        }
    }

    let options: Options
    let phone: PhoneEntry
    private(set) var serial = ""
    var hwSerial: String { phone.hwSerial }
    private(set) var overUSB = false
    private(set) var usbSpeed = ""            // the Mac's view of the cable (system_profiler)
    private(set) var status: [String: Any] = [:]
    private(set) var latencyMs: Double = 0    // sensor -> decoded on the Mac, median of the last second
    private(set) var decodedFps: Double = 0
    private var host = "127.0.0.1"
    private var linkPort: UInt16 = 0
    private var statusPort: UInt16 = 0

    var name: String { phone.label }
    var uniqueID: String { "manualcamera:\(phone.hwSerial):\(options.lens):\(options.width)" }
    private(set) var intrinsics: Intrinsics?
    var clockNote: String { "phone sensor clock mapped to the Mac host clock (NTP-style over the status, ±\(String(format: "%.1f", bestRtt * 500)) ms)" }
    var onPixelBuffer: ((CVPixelBuffer, Double) -> Void)?
    /// Called on the main queue whenever the status line changes (connecting, numbers, errors).
    var onStatusText: ((String) -> Void)?
    /// Called on the main queue when it could not start (the reason, for a toast).
    var onError: ((String) -> Void)?
    private(set) var statusText = "" { didSet { let t = statusText; DispatchQueue.main.async { self.onStatusText?(t) } } }

    var formatText: String {
        let st = status["stream"] as? [String: Any] ?? [:]
        let w = st["width"] as? Int ?? 0, h = st["height"] as? Int ?? 0
        let mb = st["mbps"] as? Double ?? 0
        let codec = st["codec"] as? String ?? options.codec.uppercased()
        var s = w > 0 ? "\(w)x\(h)" : "\(options.width) px"
        s += String(format: " %.1f fps %.0f Mbit/s %@", decodedFps, mb, codec)
        if latencyMs > 0 { s += String(format: " · %.0f ms", latencyMs) }
        s += " · " + (overUSB ? "USB" + (usbSpeed.isEmpty ? "" : " " + usbSpeed) : route + " " + host)
        return s
    }

    private let q = DispatchQueue(label: "skeleton.phone")
    private var link: PhoneLink?
    private let decoder = PhoneDecoder()
    private var statusTimer: DispatchSourceTimer?
    private var started = false, stopped = false
    private var startCompletion: ((Bool) -> Void)?

    // clock: phone µs -> host seconds
    private var clockOffset: Double?          // phone seconds minus host seconds
    private var bestRtt = 1.0
    private var syncSamples: [(rtt: Double, off: Double)] = []
    private var lats: [Double] = []
    private var frameTimes: [Double] = []

    /// Chosen by Marko's hand (CONNECT, the camera list): it may start the camera even with AUTO START off.
    var userAsked = false
    private var mayKick: Bool { PhoneSource.autoStart || userAsked }

    init(phone: PhoneEntry, options: Options = .load()) { self.phone = phone; self.options = options }

    static var adbPresent: Bool { PhoneAdb.present }

    func start(completion: @escaping (Bool) -> Void) {
        startCompletion = completion
        q.async { self.bringUp() }
    }

    private func finishStart(_ ok: Bool) {
        guard let c = startCompletion else { return }
        startCompletion = nil
        DispatchQueue.main.async { c(ok) }
    }

    private func fail(_ why: String) {
        statusText = why; NSLog("[Skeleton] phone %@: %@", phone.label, why)
        DispatchQueue.main.async { self.onError?(why) }
        finishStart(false)
    }

    private func bringUp() {
        guard PhoneAdb.present else { return fail("NO ADB at \(PhoneAdb.path)") }
        let who = phone.short.uppercased()
        if let adbSerial = phone.usbSerial ?? phone.wifiSerial {
            let v = PhoneAdb.cameraVersion(adbSerial)
            guard v >= Self.minVersion else { return fail("\(who): MANUAL CAMERA v\(v) — v\(Self.minVersion) OR NEWER NEEDED (UPDATE IT)") }
        }
        statusText = "STARTING MANUAL CAMERA ON THE \(who)..."
        // tried again and again (5 s, 10 s ... 30 s) until it comes: the phone may be locked, asleep, or off adb a moment
        var wait = 5.0
        while !stopped {
            guard let err = connectRoute() else { break }
            statusText = "\(who): " + err
            DispatchQueue.main.async { self.onError?("\(who): " + err) }
            PhoneLog.line("\(phone.label): start failed: \(err); again in \(Int(wait)) s")
            Thread.sleep(forTimeInterval: wait); wait = min(30, wait * 2)
        }
        guard !stopped else { return }
        decoder.onImage = { [weak self] pb, ptsUs in self?.decoded(pb, ptsUs) }
        openLink()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        statusTimer = t
        q.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.startCompletion != nil else { return }
            self.fail("\(self.phone.short.uppercased()): NO PICTURE IN 12 S" + (self.overUSB ? "" : " (over the network: plug the USB cable)"))
        }
    }

    /// How the stream reaches the Mac now: "USB" (adb forward), "USB network" (tethering), "Wi-Fi", "Tailscale".
    private(set) var route = ""
    /// The phone's addresses seen so far (address, interface): a stream can go on over them while adb itself is gone
    /// (the Nothing's USB re-enumerates when tethering is switched; wireless adb drops with the Wi-Fi).
    private var knownAddrs: [(ip: String, iface: String)] = []
    private var lastFrameAt = 0.0
    private var recovering = false

    private func openLink() {
        link?.disconnect()
        let l = PhoneLink(host: host, port: linkPort)
        l.onConfig = { [weak self] c in self?.decoder.configure(c) }
        l.onFrame = { [weak self] au, _, pts in self?.decoder.decode(au, pts: pts) }
        l.onStatus = { [weak self] s in if s != "connected" { NSLog("[Skeleton] phone link: %@", s) } }
        link = l
        l.connect()
    }

    /// Chooses the way to the phone and makes sure its camera is in SKELETON mode at the right bit rate. nil = done,
    /// else why not. Used at the start and by the watchdog after a drop.
    private func connectRoute() -> String? {
        let fresh = PhoneAdb.phones().first { $0.hwSerial == phone.hwSerial }
        let adbSerial = fresh?.usbSerial ?? fresh?.wifiSerial
        if let a = adbSerial {
            for x in PhoneAdb.addresses(a) where !knownAddrs.contains(where: { $0.ip == x.ip }) { knownAddrs.append(x) }
            if let w = fresh?.wifiSerial, let h = w.split(separator: ":").first, !knownAddrs.contains(where: { $0.ip == String(h) }) {
                knownAddrs.append((String(h), "adb"))
            }
        }
        syncSamples = []; clockOffset = nil
        if let u = fresh?.usbSerial, let lp = PhoneAdb.forward(u, remote: 48100), let sp = PhoneAdb.forward(u, remote: 48102) {
            serial = u; overUSB = true; host = "127.0.0.1"; linkPort = lp; statusPort = sp; route = "USB"
            if usbSpeed.isEmpty { usbSpeed = PhoneAdb.macUsbSpeed(model: phone.model) }
        } else {
            overUSB = false; linkPort = 48100; statusPort = 48102
            if let a = adbSerial { serial = a }
            // the camera must answer before its addresses can be measured: started if none answers yet
            var best = bestAddress()
            if best == nil, let a = adbSerial {
                startCamera(a, mbps: options.mbpsWifi)
                let deadline = Date().addingTimeInterval(12)
                while best == nil && Date() < deadline && !stopped { Thread.sleep(forTimeInterval: 0.5); best = bestAddress() }
            }
            guard let b = best else {
                return adbSerial == nil ? "NOT ON ADB AND NOT REACHABLE" : "NOT REACHABLE OVER THE NETWORK (\(knownAddrs.map { $0.ip }.joined(separator: ", ")))"
            }
            host = b.ip
            route = b.iface.hasPrefix("wlan") ? "Wi-Fi" : (b.iface.hasPrefix("tun") || b.ip.hasPrefix("100.")) ? "Tailscale"
                : (b.iface.hasPrefix("rndis") || b.iface.hasPrefix("ncm") || b.iface.hasPrefix("usb")) ? "USB network" : "network"
            NSLog("[Skeleton] phone %@: %@ via %@ (%@, %.0f ms)", phone.label, route, host, b.iface, b.rtt * 1000)
        }
        // SKELETON mode at the bit rate this route carries (the tethered USB network carries what the cable does)
        let want = overUSB || route == "USB network" ? options.mbps : options.mbpsWifi
        var st = fetchStatus()
        let asked = (st?["asked"] as? [String: Any])?["mbps"] as? Int
        if st?["mode"] as? String != "skeleton" || asked != want {
            guard let a = adbSerial else { return st == nil ? "THE CAMERA DOES NOT ANSWER" : nil }
            startCamera(a, mbps: want, forceStop: kicks >= 2)
            let deadline = Date().addingTimeInterval(12)
            st = nil
            while Date() < deadline && !stopped {
                if let s = fetchStatus(), s["mode"] as? String == "skeleton" { st = s; break }
                Thread.sleep(forTimeInterval: 0.4)
            }
            if st == nil { return !lockedNote.isEmpty ? lockedNote : !mayKick ? "NOT STARTED (AUTO START IS OFF: CONNECT)" : "THE CAMERA DID NOT ANSWER (phone unlocked? Manual Camera allowed the camera?)" }
        }
        return nil
    }

    /// The screen on and unlocked (a lock without a PIN is dismissed; a PIN is never entered: false = "UNLOCK THE PHONE").
    private func wakeAndCheckUnlocked(_ serial: String) -> Bool {
        let w = PhoneAdb.shell(serial, "dumpsys power | grep -m1 mWakefulness=")
        if !w.contains("Awake") { PhoneAdb.shell(serial, "input keyevent KEYCODE_WAKEUP"); Thread.sleep(forTimeInterval: 0.6) }
        func locked() -> Bool { PhoneAdb.shell(serial, "dumpsys window | grep -m1 isKeyguardShowing").contains("isKeyguardShowing=true") }
        if !locked() { return true }
        PhoneAdb.shell(serial, "wm dismiss-keyguard"); Thread.sleep(forTimeInterval: 0.8)
        return !locked()
    }

    private var lockedNote = ""

    private func startCamera(_ serial: String, mbps: Int, forceStop: Bool = false) {
        guard mayKick else { return }
        if !wakeAndCheckUnlocked(serial) {
            lockedNote = "UNLOCK THE \(phone.short.uppercased()) (its screen lock is on)"
            PhoneLog.line("\(phone.label): locked with a PIN: waiting for Marko")
            return
        }
        lockedNote = ""
        if forceStop { PhoneAdb.shell(serial, "am force-stop \(Self.package)"); Thread.sleep(forTimeInterval: 0.8) }
        PhoneLog.line("\(phone.label): camera started (skeleton, \(mbps) Mbit/s\(forceStop ? ", after force-stop" : ""))")
        let o = options
        PhoneAdb.run(["-s", serial, "shell", "am", "start", "-n", Self.activity, "--es", "mode", "skeleton", "--es", "lens", o.lens,
                      "--ei", "width", "\(o.width)", "--ei", "fps", "\(o.fps)", "--ei", "mbps", "\(mbps)",
                      "--es", "codec", o.codec, "--ei", "gop", "1", "--es", "lock", "ae,awb", "--es", "flicker", "50",
                      "--es", "stab", "off", "--ez", "dim", "true"])
    }

    /// The phone's address whose status answers fastest (Wi-Fi, the tethered USB network, Tailscale), or nil.
    private func bestAddress() -> (ip: String, iface: String, rtt: Double)? {
        var best: (ip: String, iface: String, rtt: Double)?
        for a in knownAddrs { if let r = Self.statusRtt(a.ip), best == nil || r < best!.rtt { best = (a.ip, a.iface, r) } }
        return best
    }

    /// The watchdog: no picture for 3 s = the way to the phone is found again (adb's transport changed, the Wi-Fi dropped,
    /// tethering switched on or off), the camera started again only if it lost SKELETON mode, and the stream reopened.
    /// Kicks in a row without a picture since: the 2nd and later force-stop Manual Camera before starting it again.
    private var kicks = 0
    private var lastGoodAt = 0.0

    private func recover(_ why: String) {
        recovering = true
        defer { recovering = false }
        let who = phone.short.uppercased()
        if hostNow() - lastGoodAt > 20 { } else { kicks = 0 }      // a picture flowed lately: start the ladder again
        var wait = 2.0
        while !stopped {
            kicks += 1
            statusText = "\(who): RECONNECTING" + (kicks > 1 ? " (\(kicks))" : "") + "..."
            PhoneLog.line("\(phone.label): kick \(kicks) (\(why))\(kicks >= 2 ? ": force-stop and start" : "")")
            link?.disconnect()
            // a camera that still says SKELETON but sends nothing is started again from the 2nd kick on
            if kicks >= 2, let a = PhoneAdb.phones().first(where: { $0.hwSerial == phone.hwSerial }).flatMap({ $0.usbSerial ?? $0.wifiSerial }) {
                startCamera(a, mbps: overUSB || route == "USB network" ? options.mbps : options.mbpsWifi, forceStop: true)
            }
            if connectRoute() == nil, !stopped {
                openLink()
                lastFrameAt = hostNow()          // 3 s grace for the first frame
                PhoneLog.line("\(phone.label): reconnected over \(route) \(host)")
                return
            }
            Thread.sleep(forTimeInterval: wait); wait = min(30, wait * 2)
        }
    }

    /// A black picture for 3 s is a missing picture too (a camera taken by another app, a covered lens is rare on a tripod).
    private var blackSince = 0.0
    private var lumCheckAt = 0.0

    /// One status request to <host>:48102: its round trip in seconds, or nil (not answering in skeleton mode).
    static func statusRtt(_ host: String) -> Double? {
        guard let url = URL(string: "http://\(host):48102/status") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0); var ok = false
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d = d, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["mode"] as? String == "skeleton" { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok ? Date().timeIntervalSince(t0) : nil
    }

    private func tick() {
        guard !stopped else { return }
        if let s = fetchStatus() {
            status = s
            if let c = s["calibration"] as? [String: Any], let k = c["stream_intrinsics"] as? [String: Any],
               let fx = k["fx"] as? Double, let fy = k["fy"] as? Double, let cx = k["cx"] as? Double, let cy = k["cy"] as? Double,
               let w = k["width"] as? Int, let h = k["height"] as? Int, w > 0 {
                intrinsics = Intrinsics(fx: fx, fy: fy, cx: cx, cy: cy, k: [0, 0, 0, 0], width: w, height: h)
            }
        }
        if !lats.isEmpty { latencyMs = lats.sorted()[lats.count / 2] * 1000; lats.removeAll() }
        let now = hostNow()
        frameTimes = frameTimes.filter { now - $0 < 2 }
        decodedFps = Double(frameTimes.count) / 2
        if started && !recovering {
            if now - lastFrameAt > 3 { recover("no picture for 3 s") }
            else if blackSince > 0 && now - blackSince > 3 { blackSince = 0; recover("black picture for 3 s") }
            else { statusText = formatText }
        }
    }

    /// GET /status, with the clock exchange: the phone's clock_us against the middle of the round trip.
    private func fetchStatus() -> [String: Any]? {
        guard let url = URL(string: "http://\(host):\(statusPort)/status") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 2; req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        let t0 = hostNow()
        var t1 = t0
        URLSession.shared.dataTask(with: req) { data, _, _ in
            t1 = self.hostNow()
            if let d = data { out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        if let o = out, let c = o["clock_us"] as? Double ?? (o["clock_us"] as? Int).map(Double.init) {
            let rtt = t1 - t0
            syncSamples.append((rtt, c / 1e6 - (t0 + t1) / 2))
            if syncSamples.count > 20 { syncSamples.removeFirst() }
            if let best = syncSamples.min(by: { $0.rtt < $1.rtt }) { clockOffset = best.off; bestRtt = best.rtt }
        }
        return out
    }

    private func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func decoded(_ pb: CVPixelBuffer, _ ptsUs: Int64) {
        let now = hostNow()
        lastFrameAt = now
        if now - lumCheckAt > 0.5 {
            lumCheckAt = now
            let lum = meanLuminance(pb)
            q.async { if lum < 4 { if self.blackSince == 0 { self.blackSince = now } } else { self.blackSince = 0; self.lastGoodAt = now; self.kicks = 0 } }
        }
        var t = now
        if let off = clockOffset {
            let taken = Double(ptsUs) / 1e6 - off
            let lat = now - taken
            if lat > -0.05 && lat < 5 { t = min(taken, now); q.async { self.lats.append(lat) } }
        }
        q.async { self.frameTimes.append(now) }
        if !started {
            started = true
            statusText = "PICTURE FROM THE \(phone.short.uppercased())"
            finishStart(true)
        }
        onPixelBuffer?(pb, t)
    }

    func stop() {
        onPixelBuffer = nil
        stopped = true
        statusTimer?.cancel(); statusTimer = nil
        link?.disconnect(); link = nil
        let s = serial, usb = overUSB, lp = linkPort, sp = statusPort
        guard !s.isEmpty else { return }
        DispatchQueue.global().async {
            // the camera back to its own settings (Marko's), the forwards removed
            PhoneAdb.run(["-s", s, "shell", "am", "start", "-n", Self.activity, "--es", "mode", "off"])
            if usb && lp > 0 { PhoneAdb.run(["-s", s, "forward", "--remove", "tcp:\(lp)"]); PhoneAdb.run(["-s", s, "forward", "--remove", "tcp:\(sp)"]) }
        }
    }
}

// MARK: - Mantra Link, the Mac side (MANTRA_NDI shared/kotlin/.../Link.kt; as MANTRA_VIRTUAL_CAM Sources/Link.swift)

struct PhoneStreamConfig { let hevc: Bool; let width: Int; let height: Int; let vps: Data; let sps: Data; let pps: Data }

final class PhoneLink {
    var onConfig: ((PhoneStreamConfig) -> Void)?
    var onFrame: ((Data, Bool, Int64) -> Void)?          // access unit (Annex-B), keyframe, pts µs
    var onStatus: ((String) -> Void)?
    private var conn: NWConnection?
    private let q = DispatchQueue(label: "skeleton.phone.link")
    private let endpoint: NWEndpoint
    private var wanted = false

    init(host: String, port: UInt16) { endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!) }

    func disconnect() { wanted = false; conn?.cancel(); conn = nil }

    func connect() {
        wanted = true
        let p = NWParameters.tcp
        (p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let c = NWConnection(to: endpoint, using: p)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready: self.onStatus?("connected"); self.send(12, Data([2])); self.readHeader()   // MODE 2: the camera's own stream
            case .failed(let e): self.onStatus?("failed: \(e)"); self.retry()
            case .waiting(let e): self.onStatus?("waiting: \(e)"); self.retry()
            default: break
            }
        }
        c.start(queue: q)
    }

    private func retry() {
        conn?.cancel(); conn = nil
        guard wanted else { return }
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in if self?.wanted == true { self?.connect() } }
    }

    private func send(_ t: UInt8, _ payload: Data) {
        var d = Data([t]); var n = UInt32(payload.count).bigEndian
        d.append(Data(bytes: &n, count: 4)); d.append(payload)
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func readHeader() {
        conn?.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] d, _, _, err in
            guard let self = self else { return }
            guard let d = d, d.count == 5, err == nil else { if self.wanted { self.onStatus?("the camera went away"); self.retry() }; return }
            let b = [UInt8](d)
            let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            guard n >= 0 && n < 16 << 20 else { self.onStatus?("broken stream"); self.retry(); return }
            if n == 0 { self.handle(b[0], Data()); self.readHeader(); return }
            self.conn?.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] d, _, _, err in
                guard let self = self else { return }
                guard let d = d, d.count == n, err == nil else { if self.wanted { self.onStatus?("the camera went away"); self.retry() }; return }
                self.handle(b[0], d)
                self.readHeader()
            }
        }
    }

    private func handle(_ t: UInt8, _ p: Data) {
        let b = [UInt8](p)
        func int(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i+1]) << 16 | Int(b[i+2]) << 8 | Int(b[i+3]) }
        switch t {
        case 4:     // SCONFIG codec, w, h, vps, sps, pps
            guard b.count >= 21 else { return }
            var i = 9; var parts: [Data] = []
            for _ in 0..<3 { let n = int(i); i += 4; guard i + n <= b.count else { return }; parts.append(Data(b[i..<(i + n)])); i += n }
            onConfig?(PhoneStreamConfig(hevc: b[0] == 1, width: int(1), height: int(5), vps: parts[0], sps: parts[1], pps: parts[2]))
        case 5:     // SFRAME flags, pts µs, access unit
            guard b.count > 9 else { return }
            var pts: Int64 = 0; for k in 1...8 { pts = pts << 8 | Int64(b[k]) }
            onFrame?(Data(b[9...]), b[0] & 1 == 1, pts)
        default: break
        }
    }
}

// MARK: - VideoToolbox (as MANTRA_VIRTUAL_CAM Sources/Decoder.swift), BGRA out

final class PhoneDecoder {
    var onImage: ((CVPixelBuffer, Int64) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var hevc = true
    private let lock = NSLock()

    private func nalType(_ n: Data) -> Int { let b0 = Int(n[n.startIndex]); return hevc ? (b0 >> 1) & 0x3f : b0 & 0x1f }

    func configure(_ c: PhoneStreamConfig) {
        lock.lock(); defer { lock.unlock() }
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        hevc = c.hevc
        // parameter sets by NAL type (H.265's csd-0 holds VPS, SPS and PPS at once: MANTRA_VIRTUAL_CAM LESSONS 4)
        let all = [c.vps, c.sps, c.pps].flatMap { PhoneDecoder.nalUnits($0) }.filter { !$0.isEmpty }
        let order = c.hevc ? [32, 33, 34] : [7, 8]
        let sets = order.compactMap { t in all.first(where: { nalType($0) == t }) }
        guard sets.count == order.count else { NSLog("[Skeleton] phone: parameter sets missing (%d units)", all.count); return }
        var fmt: CMFormatDescription?
        let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(d.count, 1)); d.copyBytes(to: p, count: d.count); return p }
        defer { copies.forEach { $0.deallocate() } }
        let ptrs = copies.map { UnsafePointer($0) }, sizes = sets.map { $0.count }
        let st: OSStatus = ptrs.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in
            c.hevc ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
                   : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        } }
        guard st == noErr, let f = fmt else { NSLog("[Skeleton] phone: format description failed %d", st); return }
        format = f
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        var cb = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refCon, _, status, _, image, pts, _ in
            guard status == noErr, let img = image, let r = refCon else { return }
            Unmanaged<PhoneDecoder>.fromOpaque(r).takeUnretainedValue().onImage?(img, pts.value)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: spec as CFDictionary,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: &cb, decompressionSessionOut: &s)
        if r != noErr { NSLog("[Skeleton] phone: decoder failed %d", r) }
        if let s = s { VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        session = s
    }

    func decode(_ annexB: Data, pts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let s = session, let f = format else { return }
        var avcc = Data(capacity: annexB.count + 16)
        for nal in PhoneDecoder.nalUnits(annexB) where !nal.isEmpty {
            let t = nalType(nal)
            if hevc ? (32...34).contains(t) : (t == 7 || t == 8) { continue }
            var n = UInt32(nal.count).bigEndian; avcc.append(Data(bytes: &n, count: 4)); avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }
        let len = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block) == noErr,
              let b = block else { return }
        let ok = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: len) }
        guard ok == noErr else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = len
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: b, formatDescription: f, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sb = sample else { return }
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], frameRefcon: nil, infoFlagsOut: nil)
    }

    /// The NAL units of an Annex-B buffer (00 00 01 or 00 00 00 01 before each).
    static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d); var starts: [(Int, Int)] = []; var i = 0
        while i + 3 <= b.count {
            if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 { starts.append((i, 3)); i += 3 }
            else if i + 4 <= b.count && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 { starts.append((i, 4)); i += 4 }
            else { i += 1 }
        }
        if starts.isEmpty { return b.isEmpty ? [] : [d] }
        var out: [Data] = []
        for (k, (s, l)) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].0 : b.count
            if s + l < end { out.append(Data(b[(s + l)..<end])) }
        }
        return out
    }
}

// MARK: - adb (never on the main thread: MANTRA_VIRTUAL_CAM LESSONS 7)

struct PhoneDevice { let serial: String; let model: String; var wifi: Bool { serial.contains(":") } }

/// One phone (by its hardware serial), reachable on USB, on adb over Wi-Fi, or both.
struct PhoneEntry {
    let hwSerial: String
    let model: String          // "Pixel 7", "A142"
    let maker: String          // "Google", "Nothing"
    var usbSerial: String?
    var wifiSerial: String?
    var version: Int
    var short: String { model.lowercased().hasPrefix(maker.lowercased()) || maker == "Google" ? model : maker + " " + model }
    var transport: String { usbSerial != nil ? "USB" : "Wi-Fi" }
    var label: String { "Manual Camera (\(short), \(transport))" }
    var savedID: String { "manualcamera:" + hwSerial }
    var key: String { label + "|\(version)" }
}

enum PhoneAdb {
    static let path = NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
    static var present: Bool { FileManager.default.isExecutableFile(atPath: path) }

    @discardableResult static func run(_ args: [String], timeout: Double = 15) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = o
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate() }
        return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @discardableResult static func shell(_ serial: String, _ cmd: String) -> String { run(["-s", serial, "shell", cmd]) }

    static func devices() -> [PhoneDevice] {
        run(["devices", "-l"]).split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, f[1] == "device" else { return nil }
            let model = f.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            return PhoneDevice(serial: String(f[0]), model: model)
        }
    }

    /// Every phone with Manual Camera, grouped by its hardware serial (USB and Wi-Fi of one phone are one entry).
    static func phones() -> [PhoneEntry] {
        var out: [PhoneEntry] = []
        for d in devices() where !d.serial.hasPrefix("emulator-") {
            let v = cameraVersion(d.serial)
            guard v > 0 else { continue }           // a phone without Manual Camera is never touched
            let props = shell(d.serial, "getprop ro.serialno; getprop ro.product.model; getprop ro.product.manufacturer")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let hw = props.count > 0 && !props[0].isEmpty ? props[0] : d.serial
            let model = props.count > 1 && !props[1].isEmpty ? props[1] : d.model.replacingOccurrences(of: "_", with: " ")
            let maker = props.count > 2 ? props[2] : ""
            if let i = out.firstIndex(where: { $0.hwSerial == hw }) {
                if d.wifi { out[i].wifiSerial = d.serial } else { out[i].usbSerial = d.serial }
            } else {
                out.append(PhoneEntry(hwSerial: hw, model: model, maker: maker, usbSerial: d.wifi ? nil : d.serial,
                                      wifiSerial: d.wifi ? d.serial : nil, version: v))
            }
        }
        // the Pixel first, then by name: a stable order in the camera list
        return out.sorted { a, b in
            let pa = a.model.lowercased().contains("pixel"), pb = b.model.lowercased().contains("pixel")
            return pa != pb ? pa : a.label < b.label
        }
    }

    /// `adb forward tcp:0 tcp:<remote>`: a free local port, chosen by adb (several phones at once never collide).
    static func forward(_ serial: String, remote: Int) -> UInt16? {
        UInt16(run(["-s", serial, "forward", "tcp:0", "tcp:\(remote)"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The phone's IPv4 addresses a Mac can reach: Wi-Fi, USB tethering (rndis/ncm/usb), Ethernet, Tailscale (tun).
    /// Mobile data (ccmni, rmnet) and loopback are left out.
    static func addresses(_ serial: String) -> [(ip: String, iface: String)] {
        shell(serial, "ip -4 -o addr show").split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let i = f.firstIndex(of: "inet"), i + 1 < f.count else { return nil }
            let iface = String(f[1]), ip = String(f[i + 1].split(separator: "/")[0])
            let ok = ["wlan", "rndis", "ncm", "usb", "eth", "tun"].contains { iface.hasPrefix($0) }
            return ok ? (ip, iface) : nil
        }
    }

    /// The phone's own Wi-Fi address (wlan0), or nil.
    static func wifiAddress(_ serial: String) -> String? {
        let out = shell(serial, "ip -4 addr show wlan0")
        guard let r = out.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else { return nil }
        return String(out[r].dropFirst(5))
    }

    static func cameraVersion(_ serial: String) -> Int {
        let out = run(["-s", serial, "shell", "dumpsys", "package", PhoneSource.package])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("versionCode=") }),
              let r = line.range(of: #"versionCode=(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(line[r].dropFirst("versionCode=".count)) ?? 0
    }

    /// The Mac's view of the phone on the cable: "10 Gb/s", "5 Gb/s", "480 Mb/s" (system_profiler).
    static func macUsbSpeed(model: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler"); p.arguments = ["SPUSBDataType", "-json"]
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        func walk(_ items: [[String: Any]]) -> String? {
            for it in items {
                let name = (it["_name"] as? String ?? "").lowercased()
                if name.contains("pixel") || (!model.isEmpty && name.contains(model.lowercased().replacingOccurrences(of: "_", with: " "))) {
                    let sp = it["device_speed"] as? String ?? ""
                    switch sp {
                    case "super_speed_plus": return "10 Gb/s"
                    case "super_speed": return "5 Gb/s"
                    case "high_speed": return "480 Mb/s"
                    case "full_speed": return "12 Mb/s"
                    default: return sp
                    }
                }
                if let sub = it["_items"] as? [[String: Any]], let r = walk(sub) { return r }
            }
            return nil
        }
        return walk(root["SPUSBDataType"] as? [[String: Any]] ?? []) ?? ""
    }
}

/// One line per kick, connect and failure: ~/Library/Logs/Skeleton/phones.log (Marko: "log each kick").
enum PhoneLog {
    private static let q = DispatchQueue(label: "skeleton.phone.log")
    static func line(_ text: String) {
        NSLog("[Skeleton] %@", text)
        q.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Skeleton")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("phones.log")
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let l = Data((df.string(from: Date()) + "  " + text + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(l); try? h.close() } else { try? l.write(to: f) }
        }
    }
}
