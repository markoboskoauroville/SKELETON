// PhoneSource.swift: "Manual Camera (Pixel, USB)", the Pixel 7 running Mantra Manual Camera v221+ as a FrameSource.
//
// Marko, 16.11.2026: "if I connect via USB my Pixel phone, this app needs to understand how to adjust the phone and the
// camera to get the best possible picture available on this USB connection ... start the camera itself, adjust the
// settings of this phone and being able to use it for posing."
//
// How: adb finds the phone (USB first), `adb forward` puts the camera's Mantra Link (48100) and its status (48102) on
// 127.0.0.1:48110 / :48112, `am start ... --es mode skeleton` starts the camera with our choices (lens, size, fps,
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
    static let displayName = "Manual Camera (Pixel, USB)"
    static let package = "com.mantraproductions.manualcamera"
    static let activity = "com.mantraproductions.manualcamera/com.mantraproductions.ndi.MainActivity"
    static let minVersion = 221

    /// The run's choices (UserDefaults phone.lens / phone.width / phone.fps / phone.mbps / phone.codec; defaults below).
    struct Options {
        var lens = "back_main"      // back_main (1x), back_wide (ultrawide), front, or L1..Ln
        var width = 1920            // 1920 (1080p) or 3840 (4K) or 1280
        var fps = 30
        var mbps = 40
        var codec = "hevc"          // hevc or h264
        static func load() -> Options {
            let d = UserDefaults.standard; var o = Options()
            if let v = d.string(forKey: "phone.lens"), !v.isEmpty { o.lens = v }
            if d.integer(forKey: "phone.width") > 0 { o.width = d.integer(forKey: "phone.width") }
            if d.integer(forKey: "phone.fps") > 0 { o.fps = d.integer(forKey: "phone.fps") }
            if d.integer(forKey: "phone.mbps") > 0 { o.mbps = d.integer(forKey: "phone.mbps") }
            if let v = d.string(forKey: "phone.codec"), !v.isEmpty { o.codec = v }
            return o
        }
    }

    let options: Options
    private(set) var serial = ""
    private(set) var hwSerial = ""
    private(set) var overUSB = false
    private(set) var usbSpeed = ""            // the Mac's view of the cable (system_profiler)
    private(set) var status: [String: Any] = [:]
    private(set) var latencyMs: Double = 0    // sensor -> decoded on the Mac, median of the last second
    private(set) var decodedFps: Double = 0
    private var host = "127.0.0.1"
    private var linkPort: UInt16 = 48110
    private var statusPort: UInt16 = 48112

    var name: String { Self.displayName }
    var uniqueID: String { "manualcamera:\(hwSerial.isEmpty ? serial : hwSerial):\(options.lens):\(options.width)" }
    private(set) var intrinsics: Intrinsics?
    var clockNote: String { "phone sensor clock mapped to the Mac host clock (NTP-style over the status, ±\(String(format: "%.1f", bestRtt * 500)) ms)" }
    var onPixelBuffer: ((CVPixelBuffer, Double) -> Void)?
    /// Called on the main queue whenever the status line changes (connecting, numbers, errors).
    var onStatusText: ((String) -> Void)?
    private(set) var statusText = "" { didSet { let t = statusText; DispatchQueue.main.async { self.onStatusText?(t) } } }

    var formatText: String {
        let st = status["stream"] as? [String: Any] ?? [:]
        let w = st["width"] as? Int ?? 0, h = st["height"] as? Int ?? 0
        let fps = st["fps"] as? Double ?? 0, mb = st["mbps"] as? Double ?? 0
        let codec = st["codec"] as? String ?? options.codec.uppercased()
        var s = w > 0 ? "\(w)x\(h)" : "\(options.width) px"
        s += String(format: " %.1f fps %.0f Mbit/s %@", fps > 0 ? fps : decodedFps, mb, codec)
        if latencyMs > 0 { s += String(format: " · %.0f ms", latencyMs) }
        s += " · " + (overUSB ? "USB " + (usbSpeed.isEmpty ? "cable" : usbSpeed) : "Wi-Fi (plug the cable for the best picture)")
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

    init(options: Options = .load()) { self.options = options }

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

    private func fail(_ why: String) { statusText = why; NSLog("[Skeleton] phone: %@", why); finishStart(false) }

    private func bringUp() {
        guard PhoneAdb.present else { return fail("NO ADB at \(PhoneAdb.path)") }
        statusText = "LOOKING FOR THE PIXEL ON ADB..."
        guard let d = PhoneAdb.pickPhone() else { return fail("NO PIXEL ON ADB: plug the Pixel 7 in with the USB-C cable (USB debugging on)") }
        serial = d.serial; overUSB = !d.wifi
        hwSerial = PhoneAdb.shell(serial, "getprop ro.serialno").trimmingCharacters(in: .whitespacesAndNewlines)
        let v = PhoneAdb.cameraVersion(serial)
        guard v > 0 else { return fail("MANUAL CAMERA IS NOT INSTALLED ON THE PIXEL") }
        guard v >= Self.minVersion else { return fail("MANUAL CAMERA v\(v) ON THE PIXEL: v\(Self.minVersion) OR NEWER NEEDED (UPDATE IT)") }
        if overUSB {
            host = "127.0.0.1"; linkPort = 48110; statusPort = 48112
            PhoneAdb.run(["-s", serial, "forward", "tcp:\(linkPort)", "tcp:48100"])
            PhoneAdb.run(["-s", serial, "forward", "tcp:\(statusPort)", "tcp:48102"])
            usbSpeed = PhoneAdb.macUsbSpeed(model: d.model)
        } else {
            host = String(serial.split(separator: ":").first ?? ""); linkPort = 48100; statusPort = 48102
        }
        // keep the phone awake on the cable while the camera runs (stays on while charging over USB)
        PhoneAdb.shell(serial, "input keyevent KEYCODE_WAKEUP")
        statusText = "STARTING MANUAL CAMERA ON THE PIXEL..."
        let o = options
        PhoneAdb.run(["-s", serial, "shell", "am", "start", "-n", Self.activity, "--es", "mode", "skeleton", "--es", "lens", o.lens,
                      "--ei", "width", "\(o.width)", "--ei", "fps", "\(o.fps)", "--ei", "mbps", "\(o.mbps)", "--es", "codec", o.codec,
                      "--ei", "gop", "1", "--es", "lock", "ae,awb", "--es", "flicker", "50", "--es", "stab", "off", "--ez", "dim", "true"])
        // the camera answers its status in skeleton mode
        let deadline = Date().addingTimeInterval(12)
        var ready = false
        while Date() < deadline && !stopped {
            if let s = fetchStatus(), (s["mode"] as? String) == "skeleton" { ready = true; break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard !stopped else { return }
        guard ready else { return fail("THE CAMERA DID NOT ANSWER (is the Pixel unlocked? Manual Camera in front?)") }
        statusText = "CONNECTING TO THE CAMERA'S STREAM..."
        decoder.onImage = { [weak self] pb, ptsUs in self?.decoded(pb, ptsUs) }
        let l = PhoneLink(host: host, port: linkPort)
        l.onConfig = { [weak self] c in self?.decoder.configure(c) }
        l.onFrame = { [weak self] au, _, pts in self?.decoder.decode(au, pts: pts) }
        l.onStatus = { [weak self] s in if s != "connected" { self?.statusText = "LINK: " + s } }
        link = l
        l.connect()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        statusTimer = t
        q.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.startCompletion != nil else { return }
            self.fail("NO PICTURE FROM THE PIXEL IN 12 S" + (self.overUSB ? "" : " (over Wi-Fi: plug the USB cable)"))
        }
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
        if started { statusText = formatText }
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
        var t = now
        if let off = clockOffset {
            let taken = Double(ptsUs) / 1e6 - off
            let lat = now - taken
            if lat > -0.05 && lat < 5 { t = min(taken, now); q.async { self.lats.append(lat) } }
        }
        q.async { self.frameTimes.append(now) }
        if !started {
            started = true
            statusText = "PICTURE FROM THE PIXEL"
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
            if usb { PhoneAdb.run(["-s", s, "forward", "--remove", "tcp:\(lp)"]); PhoneAdb.run(["-s", s, "forward", "--remove", "tcp:\(sp)"]) }
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

    /// The Pixel (any phone with Manual Camera when no Pixel), on USB before Wi-Fi. Never another phone by mistake:
    /// a phone without Manual Camera is skipped.
    static func pickPhone() -> PhoneDevice? {
        let all = devices().filter { !$0.serial.hasPrefix("emulator-") }
        let ranked = all.sorted { a, b in
            let pa = a.model.lowercased().contains("pixel"), pb = b.model.lowercased().contains("pixel")
            if pa != pb { return pa }
            return !a.wifi && b.wifi
        }
        // one physical phone may be listed twice (USB and Wi-Fi): the USB one comes first in the ranking
        return ranked.first { a in a.model.lowercased().contains("pixel") && cameraVersion(a.serial) > 0 }
            ?? ranked.first { cameraVersion($0.serial) > 0 }
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
