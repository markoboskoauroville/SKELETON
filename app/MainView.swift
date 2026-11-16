// MainView.swift: the window's content: the stage, the fading controls, the camera, the poses, the session.
import AppKit
import AVFoundation

private let MONO = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

/// A macOS switch BEFORE its title (workflow-interface.md, 16.11.2026).
final class SwitchRow: NSStackView {
    let sw = NSSwitch()
    let label: NSTextField
    var onChange: ((Bool) -> Void)?
    var isOn: Bool { get { sw.state == .on } set { sw.state = newValue ? .on : .off } }
    init(_ title: String, on: Bool) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = MONO; label.textColor = .white
        sw.state = on ? .on : .off
        sw.target = self; sw.action = #selector(flip)
        sw.setAccessibilityLabel(title)
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(labelClicked)))
        orientation = .horizontal; spacing = 6; alignment = .centerY
        addArrangedSubview(sw); addArrangedSubview(label)
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func flip() { onChange?(isOn) }
    @objc func labelClicked() { isOn.toggle(); onChange?(isOn) }
}

/// One camera view of the 1 to 3: its pipeline, its stage, its calibration and its recent poses.
final class Slot {
    let pipe = Pipeline()
    let stage = StageView()
    var device: AVCaptureDevice?
    var intr: Intrinsics?
    var intrInfo: StoredIntrinsics?
    var extr: StoredExtrinsics?          // pose relative to camera 1 (nil for camera 1)
    var offset = 0.0                     // seconds this camera shows a moment later than camera 1
    var hist: [(t: Double, pose: Pose?, size: CGSize)] = []
    var size = CGSize.zero
    var formatText = ""
    var lastBoard: (t: Double, pts: [V2])?
    var prevBoard: [V2]?
    var stable = 0
    var detectBusy = false
    var lastDetect = 0.0
    var sig: [(t: Double, lum: Double, motion: Double)] = []
    var sizeWarned = false
    var uid: String { device?.uniqueID ?? "" }
}

enum CalStep: Equatable { case idle, intrinsics(Int), pair(Int), measure }

final class MainView: NSView, NSMenuDelegate {
    override var isFlipped: Bool { true }
    var slots: [Slot] = [Slot()]
    var stage: StageView { slots[0].stage }
    let controls = NSView()
    let camSeg = NSSegmentedControl(labels: ["1 CAMERA", "2 CAMERAS", "3 CAMERAS"], trackingMode: .selectOne, target: nil, action: nil)
    let camBPopup = NSPopUpButton()
    let camCPopup = NSPopUpButton()
    var calStep = CalStep.idle
    var calViews: [[V2]] = []
    var calPairs: [([V2], [V2])] = []
    var lastCap: [V2]?
    var measureStart = 0.0
    var lastTri: TriResult?
    var a3 = false
    var wizardClear: Date?
    let calibrateButton = NSButton()
    let multiRow = NSStackView()
    var devices: [AVCaptureDevice] = []
    var device: AVCaptureDevice? { slots[0].device }
    let defaults = UserDefaults.standard

    let cameraPopup = NSPopUpButton()
    let savedPopup = NSPopUpButton()
    let levelSeg = NSSegmentedControl(labels: Level.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    var mirrorSw: SwitchRow!, anglesSw: SwitchRow!, onlySw: SwitchRow!, soundSw: SwitchRow!, voiceSw: SwitchRow!
    let permsButton = NSButton()
    let sessionButton = NSButton()
    let skipButton = NSButton()
    let titleLabel = NSTextField(labelWithString: "")
    let recordButton = NSButton()
    let renderButton = NSButton()
    let recPopup = NSPopUpButton()
    var recordings: [URL] = []
    var recorder: Recorder?
    let presetPopup = NSPopUpButton()
    var useCleanSw: SwitchRow!
    var toolBusy = false
    var renderProc: Process?

    var builtin: [NamedPose] = []
    var saved: [NamedPose] = []
    var session: [NamedPose]?
    var sessionIndex = 0
    var lastMove = Date()
    var openMenus = 0
    var pendingCamera: String?
    var pendingCams: [String] = []
    var authorized = false
    let settingsPopover = NSPopover()
    let settingsText = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(slots[0].stage)
        buildControls()
        addSubview(controls)
        stage.onDropURL = { [weak self] in self?.loadPhoto($0) }
        stage.onAchieved = { [weak self] in self?.achieved() }
        wire(slots[0])
        Voice.shared.onChange = { [weak self] in self?.refreshSettings() }
        builtin = Store.builtin()
        refreshSaved()
        refreshRecordings()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: .AVCaptureDeviceWasConnected, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: .AVCaptureDeviceWasDisconnected, object: nil)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]) { [weak self] e in
            self?.wake(); return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            if e.keyCode == 49 { self?.window?.toggleFullScreen(nil); return nil }
            if e.keyCode == 15 { self?.toggleRecord(); return nil }
            return e
        }
        checkPermission(request: true)
        let n0 = max(1, min(3, defaults.integer(forKey: "camcount")))
        reloadDevices()
        if n0 > 1 { setCameraCount(n0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout and controls

    func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: MONO, .foregroundColor: NSColor.white])
        b.setAccessibilityLabel(title)
        return b
    }

    func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = 16; s.alignment = .centerY
        return s
    }

    func buildControls() {
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.stringValue = "SKELETON (MANTRA)  v\(VERSION)"
        permsButton.isBordered = false
        permsButton.attributedTitle = NSAttributedString(string: "PERMISSIONS", attributes: [.font: MONO, .foregroundColor: NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1)])
        permsButton.target = self; permsButton.action = #selector(openPermissions)
        permsButton.setAccessibilityLabel("PERMISSIONS")
        let spacer0 = NSView(); spacer0.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let flex = NSView(); flex.setContentHuggingPriority(.init(1), for: .horizontal)
        let r0 = row([spacer0, titleLabel, flex, permsButton])

        cameraPopup.target = self; cameraPopup.action = #selector(cameraChosen)
        cameraPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        cameraPopup.setAccessibilityLabel("CAMERA")
        cameraPopup.menu?.delegate = self
        mirrorSw = SwitchRow("MIRROR", on: false); mirrorSw.onChange = { [weak self] on in
            guard let self = self else { return }
            self.stage.mirror = on
            if let d = self.device { self.defaults.set(on, forKey: "mirror." + d.uniqueID) }
        }
        anglesSw = SwitchRow("SHOW ANGLES", on: defaults.bool(forKey: "angles")); anglesSw.onChange = { [weak self] on in
            self?.stage.showAngles = on; self?.defaults.set(on, forKey: "angles") }
        onlySw = SwitchRow("SKELETON ONLY", on: defaults.bool(forKey: "only")); onlySw.onChange = { [weak self] on in
            self?.stage.skeletonOnly = on; self?.defaults.set(on, forKey: "only") }
        soundSw = SwitchRow("SOUND", on: defaults.object(forKey: "sound") as? Bool ?? true); soundSw.onChange = { [weak self] on in
            self?.defaults.set(on, forKey: "sound") }
        voiceSw = SwitchRow("VOICE", on: defaults.object(forKey: "voice") as? Bool ?? true); voiceSw.onChange = { [weak self] on in
            Voice.shared.enabled = on; self?.defaults.set(on, forKey: "voice"); if !on { Voice.shared.stop() } }
        Voice.shared.enabled = voiceSw.isOn
        stage.showAngles = anglesSw.isOn; stage.skeletonOnly = onlySw.isOn
        let r1 = row([cameraPopup, mirrorSw, anglesSw, onlySw, soundSw, voiceSw])

        sessionButton.isBordered = false; sessionButton.target = self; sessionButton.action = #selector(toggleSession)
        setTitle(sessionButton, "3  START SESSION")
        skipButton.isBordered = false; skipButton.target = self; skipButton.action = #selector(skip)
        setTitle(skipButton, "NEXT POSE"); skipButton.isHidden = true
        recordButton.isBordered = false; recordButton.target = self; recordButton.action = #selector(toggleRecord)
        setRecordTitle("RECORD")
        let r2 = row([button("1  LOAD POSE PHOTO", #selector(chooseFile)), button("2  FREEZE MY POSE", #selector(freeze)), sessionButton, skipButton, recordButton])

        savedPopup.target = self; savedPopup.action = #selector(savedChosen)
        savedPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        savedPopup.setAccessibilityLabel("POSES")
        savedPopup.menu?.delegate = self
        let lvl = NSTextField(labelWithString: "LEVEL"); lvl.font = MONO; lvl.textColor = .white
        levelSeg.selectedSegment = defaults.integer(forKey: "level")
        levelSeg.target = self; levelSeg.action = #selector(levelChanged)
        levelSeg.setAccessibilityLabel("LEVEL")
        stage.level = Level(rawValue: max(0, levelSeg.selectedSegment)) ?? .beginner
        let r3 = row([savedPopup, lvl, levelSeg, button("CLEAR TARGET", #selector(clearTarget)), button("SETTINGS", #selector(showSettings))])

        recPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        recPopup.setAccessibilityLabel("RECORDINGS")
        recPopup.menu?.delegate = self
        renderButton.isBordered = false; renderButton.target = self; renderButton.action = #selector(renderPressed)
        setTitle(renderButton, "RENDER MANNEQUIN")
        let rl = NSTextField(labelWithString: "RECORDINGS"); rl.font = MONO; rl.textColor = .white
        let r4 = row([rl, recPopup, renderButton])
        camSeg.selectedSegment = max(0, min(2, defaults.integer(forKey: "camcount") - 1))
        camSeg.target = self; camSeg.action = #selector(camCountChanged)
        camSeg.setAccessibilityLabel("CAMERAS")
        for p in [camBPopup, camCPopup] {
            p.widthAnchor.constraint(equalToConstant: 190).isActive = true
            p.menu?.delegate = self
        }
        camBPopup.target = self; camBPopup.action = #selector(camBChosen); camBPopup.setAccessibilityLabel("CAMERA 2")
        camCPopup.target = self; camCPopup.action = #selector(camCChosen); camCPopup.setAccessibilityLabel("CAMERA 3")
        let r5 = row([camSeg, camBPopup, camCPopup])
        calibrateButton.isBordered = false; calibrateButton.target = self; calibrateButton.action = #selector(calibratePressed)
        setTitle(calibrateButton, "CALIBRATE")
        a3 = defaults.bool(forKey: "boardA3")
        let r6 = row([calibrateButton, button("BOARD A4", #selector(boardA4)), button("BOARD A3", #selector(boardA3)), button("MEASURE DELAY", #selector(measureDelay))])
        multiRow.setViews([r6], in: .leading)
        multiRow.orientation = .vertical
        multiRow.isHidden = true
        presetPopup.addItems(withTitles: ["gentle", "standard", "strong", "yoga-hold", "dance"])
        presetPopup.selectItem(withTitle: defaults.string(forKey: "preset") ?? "standard")
        presetPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        presetPopup.target = self; presetPopup.action = #selector(presetChosen)
        presetPopup.setAccessibilityLabel("CLEAN PRESET")
        presetPopup.menu?.delegate = self
        useCleanSw = SwitchRow("USE CLEANED", on: defaults.object(forKey: "usecleaned") as? Bool ?? true)
        useCleanSw.onChange = { [weak self] on in self?.defaults.set(on, forKey: "usecleaned") }
        let r7 = row([presetPopup, button("CLEAN", #selector(cleanPressed)), button("REPORT", #selector(openReport)), useCleanSw,
                      button("EXPORT FOR CLAUDE", #selector(exportForClaude)), button("IMPORT CLAUDE ANSWER", #selector(importClaude))])
        let col = NSStackView(views: [r0, r1, r2, r3, r4, r7, r5, multiRow])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 8
        col.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        col.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: controls.leadingAnchor), col.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            col.topAnchor.constraint(equalTo: controls.topAnchor), col.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            r0.trailingAnchor.constraint(equalTo: col.trailingAnchor, constant: -14),
        ])
        settingsPopover.behavior = .transient
        let vc = NSViewController()
        settingsText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        settingsText.preferredMaxLayoutWidth = 420
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 330))
        settingsText.frame = NSRect(x: 15, y: 10, width: 420, height: 310)
        box.addSubview(settingsText)
        vc.view = box
        settingsPopover.contentViewController = vc
    }

    func setTitle(_ b: NSButton, _ t: String) {
        b.attributedTitle = NSAttributedString(string: t, attributes: [.font: MONO, .foregroundColor: NSColor.white])
        b.setAccessibilityLabel(t)
    }

    override func layout() {
        super.layout()
        let n = CGFloat(slots.count), w = bounds.width / n
        for (i, s) in slots.enumerated() { s.stage.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height) }
        let h = max(60, controls.fittingSize.height)
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    }

    // MARK: fade, menus

    func menuWillOpen(_ menu: NSMenu) { openMenus += 1 }
    func menuDidClose(_ menu: NSMenu) { openMenus = max(0, openMenus - 1); wake() }

    func wake() {
        lastMove = Date()
        if controls.isHidden { controls.isHidden = false; controls.alphaValue = 0 }
        if controls.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; controls.animator().alphaValue = 1 } }
    }

    func tick() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let ok = status == .authorized
        permsButton.isHidden = ok
        if ok && !authorized { authorized = true; reloadDevices() }
        authorized = ok
        if ok, openMenus == 0, !settingsPopover.isShown, Date().timeIntervalSince(lastMove) > 3, controls.alphaValue > 0, !controls.isHidden {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; controls.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                guard let self = self, Date().timeIntervalSince(self.lastMove) > 3 else { return }
                self.controls.isHidden = true
                NSCursor.setHiddenUntilMouseMoves(true)
            })
        }
        if session != nil { stage.needsDisplay = true }
        if let r = recorder {
            let t = Int(r.seconds)
            stage.recText = String(format: "%02d:%02d", t / 60, t % 60)
            setRecordTitle("STOP " + stage.recText!)
            stage.needsDisplay = true
        }
    }

    // MARK: record and render the mannequin

    func setRecordTitle(_ t: String) {
        let a = NSMutableAttributedString(string: "● ", attributes: [.font: MONO, .foregroundColor: StageView.red])
        a.append(NSAttributedString(string: t, attributes: [.font: MONO, .foregroundColor: NSColor.white]))
        recordButton.attributedTitle = a
        recordButton.setAccessibilityLabel(recorder == nil ? "RECORD" : "STOP RECORDING")
    }

    @objc func toggleRecord() {
        if let _ = recorder { stopRecording(); return }
        guard stage.image != nil else { stage.toast("NO CAMERA PICTURE YET"); return }
        let r = Recorder(camera: slots.map { $0.stage.cameraName }.joined(separator: " + "), mirror: stage.mirror)
        if slots.count > 1 { r.cameras = camerasHeader(); r.source = calibrated ? "triangulated" : "vision3d" }
        recorder = r
        slots[0].pipe.want3D = true
        stage.recText = "00:00"
        setRecordTitle("STOP 00:00")
    }

    func stopRecording() {
        guard recorder != nil else { return }
        let r = recorder
        slots[0].pipe.want3D = false
        recorder = nil
        stage.recText = nil
        setRecordTitle("RECORD")
        guard let rec = r else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let url = rec.write()
            DispatchQueue.main.async {
                if let u = url {
                    self.refreshRecordings()
                    self.stage.toast("RECORDED \(Int(rec.last)) S: " + u.lastPathComponent)
                } else { self.stage.toast("RECORDING TOO SHORT, NOT SAVED") }
            }
        }
    }

    /// <name>.clean.skel.json or <name>.claude.skel.json beside <name>.skel.json
    static func variant(_ u: URL, _ kind: String) -> URL {
        let n = u.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "")
        return u.deletingLastPathComponent().appendingPathComponent(n + "." + kind + ".skel.json")
    }

    static var recDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Skeleton", isDirectory: true) }

    func refreshRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: MainView.recDir, includingPropertiesForKeys: nil)) ?? []
        recordings = files.filter {
            let n = $0.lastPathComponent
            return n.hasSuffix(".skel.json") && !n.contains(".clean.") && !n.contains(".claude.")
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        recPopup.removeAllItems()
        if recordings.isEmpty { recPopup.addItem(withTitle: "NONE YET"); return }
        for u in recordings {
            var len = ""
            if let h = try? FileHandle(forReadingFrom: u) {
                let d = h.readData(ofLength: 400); try? h.close()
                if let str = String(data: d, encoding: .utf8), let r = str.range(of: "\"duration\":") {
                    let num = str[r.upperBound...].prefix { "0123456789.".contains($0) }
                    if let v = Double(num) { len = String(format: "  ·  %d:%02d", Int(v) / 60, Int(v) % 60) }
                }
            }
            var tag = ""
            if FileManager.default.fileExists(atPath: MainView.variant(u, "clean").path) { tag += "  ·  cleaned" }
            if FileManager.default.fileExists(atPath: MainView.variant(u, "claude").path) { tag += "  ·  claude" }
            recPopup.addItem(withTitle: u.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "") + len + tag)
        }
        recPopup.selectItem(at: 0)
    }

    @objc func renderPressed() { renderSelected(last: false) }

    func renderSelected(last: Bool) {
        guard renderProc == nil else { stage.toast("A RENDER IS ALREADY RUNNING"); return }
        refreshRecordings()
        let idx = last ? 0 : max(0, recPopup.indexOfSelectedItem)
        guard idx < recordings.count else { stage.toast("NO RECORDING YET: PRESS RECORD (R)"); return }
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/SKELETON/blender/render_mannequin.py").path
        let blender = "/Applications/Blender.app/Contents/MacOS/Blender"
        guard FileManager.default.fileExists(atPath: script) else { stage.toast("BLENDER PART NOT INSTALLED YET"); return }
        guard FileManager.default.fileExists(atPath: blender) else { stage.toast("BLENDER IS NOT IN /Applications"); return }
        let rec = recordings[idx]
        var src = rec
        if useCleanSw.isOn {
            let claude = MainView.variant(rec, "claude"), clean = MainView.variant(rec, "clean")
            if FileManager.default.fileExists(atPath: claude.path) { src = claude }
            else if FileManager.default.fileExists(atPath: clean.path) { src = clean }
        }
        let base = rec.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "")
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/" + base + "_mannequin.mp4")
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "19", blender, "-b", "--factory-startup", "-P", script, "--", "--in", src.path, "--out", out.path]
        p.standardOutput = pipe; p.standardError = pipe
        var buf = "", done: String?
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            buf += s
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[..<nl]).trimmingCharacters(in: .whitespaces)
                buf.removeSubrange(...nl)
                if line.hasPrefix("PROGRESS ") {
                    let t = String(line.dropFirst(9))
                    DispatchQueue.main.async { self.setTitle(self.renderButton, "RENDERING " + t); self.stage.toast("RENDERING THE MANNEQUIN " + t) }
                } else if line.hasPrefix("DONE ") { done = String(line.dropFirst(5)) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.renderProc = nil
                self.setTitle(self.renderButton, "RENDER MANNEQUIN")
                let path = done ?? out.path
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
                    let u = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                    NSWorkspace.shared.open(u)
                    self.stage.toast("MANNEQUIN READY ON THE DESKTOP")
                } else { self.stage.toast("THE RENDER FAILED (BLENDER EXIT \(proc.terminationStatus))") }
            }
        }
        do { try p.run(); renderProc = p; setTitle(renderButton, "RENDERING..."); stage.toast("RENDERING THE MANNEQUIN...") }
        catch { stage.toast("COULD NOT START BLENDER") }
    }

    // MARK: permission

    func checkPermission(request: Bool) {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        authorized = s == .authorized
        permsButton.isHidden = authorized
        if s == .notDetermined && request { AVCaptureDevice.requestAccess(for: .video) { _ in } }
    }

    @objc func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: camera

    @objc func devicesChanged() { DispatchQueue.main.async { self.reloadDevices() } }

    func reloadDevices() {
        devices = AVCameraSource.devices()
        for p in [cameraPopup, camBPopup, camCPopup] {
            p.removeAllItems()
            for d in devices { p.addItem(withTitle: d.localizedName) }
        }
        if devices.isEmpty { cameraPopup.addItem(withTitle: "NO CAMERA"); stage.cameraName = ""; return }
        var taken: [String] = []
        for k in 0..<slots.count {
            var pick: AVCaptureDevice?
            if k < pendingCams.count, !pendingCams[k].isEmpty {
                let name = pendingCams[k].lowercased()
                pick = devices.first { ($0.localizedName.lowercased().contains(name) || $0.uniqueID.lowercased() == name) && !taken.contains($0.uniqueID) }
            } else if k == 0, let name = pendingCamera?.lowercased() {
                pick = devices.first { $0.localizedName.lowercased().contains(name) || $0.uniqueID.lowercased() == name }
            }
            if pick == nil, let cur = slots[k].device { pick = devices.first { $0.uniqueID == cur.uniqueID && !taken.contains($0.uniqueID) } }
            if pick == nil, let id = defaults.string(forKey: k == 0 ? "camera" : "camera\(k)") { pick = devices.first { $0.uniqueID == id && !taken.contains($0.uniqueID) } }
            if pick == nil { pick = devices.first { !taken.contains($0.uniqueID) } }
            guard let p = pick else { continue }
            taken.append(p.uniqueID)
            let popup = [cameraPopup, camBPopup, camCPopup][k]
            if let i = devices.firstIndex(where: { $0.uniqueID == p.uniqueID }) { popup.selectItem(at: i) }
            let changed = slots[k].device?.uniqueID != p.uniqueID
            if changed || (k == 0 && pendingCamera != nil) { select(p, slot: k) }
        }
        pendingCamera = nil; pendingCams = []
    }

    @objc func cameraChosen() { chooseCamera(0, cameraPopup) }
    @objc func camBChosen() { chooseCamera(1, camBPopup) }
    @objc func camCChosen() { chooseCamera(2, camCPopup) }

    func chooseCamera(_ k: Int, _ popup: NSPopUpButton) {
        let i = popup.indexOfSelectedItem
        guard i >= 0, i < devices.count, k < slots.count else { return }
        select(devices[i], slot: k)
    }

    func wire(_ s: Slot) {
        s.pipe.onFrame = { [weak self, weak s] f in
            guard let self = self, let s = s else { return }
            self.frame(s, f)
        }
    }

    func select(_ d: AVCaptureDevice, slot k: Int) {
        let s = slots[k]
        s.device = d
        defaults.set(d.uniqueID, forKey: k == 0 ? "camera" : "camera\(k)")
        let m = defaults.object(forKey: "mirror." + d.uniqueID) as? Bool ?? d.localizedName.contains("FaceTime")
        s.stage.mirror = m
        if k == 0 { mirrorSw.isOn = m }
        s.stage.cameraName = d.localizedName
        s.size = .zero; s.hist = []; s.sizeWarned = false
        loadCalibration(s)
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let src = AVCameraSource(device: d)
        s.pipe.attach(src)
        src.start { [weak self, weak s] ok in
            guard let self = self, let s = s else { return }
            s.formatText = src.formatText
            if !ok { s.stage.toast("THE CAMERA DID NOT START") }
            self.refreshSettings()
        }
    }

    // MARK: target pose

    func setTarget(_ n: NamedPose?) {
        stage.target = n
        stage.resetHold()
        if n == nil { stage.ghost = nil; stage.comparison = nil }
        stage.needsDisplay = true
    }

    @objc func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { loadPhoto(u) }
    }

    func loadPhoto(_ url: URL) {
        stage.toast("READING THE POSE FROM THE PHOTO...")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = poseFromPhoto(url)
            DispatchQueue.main.async {
                guard let (pose, img) = r else { self.stage.toast("NO PERSON FOUND IN THAT PHOTO"); return }
                self.endSession()
                let n = NamedPose(pose: pose, name: url.deletingPathExtension().lastPathComponent, speak: nil, cues: [], thumb: img)
                Store.save(n); self.refreshSaved(); self.setTarget(n)
                self.stage.toast("TARGET POSE: " + n.name.uppercased())
            }
        }
    }

    @objc func freeze() {
        guard let pi = stage.primary, let img = stage.image else { stage.toast("NO PERSON SEEN: STAND IN FRONT OF THE CAMERA"); return }
        endSession()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        var n = NamedPose(pose: stage.people[pi], name: "Frozen " + f.string(from: Date()), speak: nil, cues: [], thumb: img)
        if stage.mirror { n.thumb = img }   // the thumbnail is kept as the camera saw it
        Store.save(n); refreshSaved(); setTarget(n)
        stage.toast("YOUR POSE IS THE TARGET")
    }

    @objc func clearTarget() { endSession(); setTarget(nil) }

    func refreshSaved() {
        saved = Store.saved()
        savedPopup.removeAllItems()
        savedPopup.addItem(withTitle: "SAVED POSES")
        for n in saved { savedPopup.addItem(withTitle: n.name) }
        savedPopup.selectItem(at: 0)
    }

    @objc func savedChosen() {
        let i = savedPopup.indexOfSelectedItem
        guard i > 0, i - 1 < saved.count else { return }
        endSession(); setTarget(saved[i - 1]); savedPopup.selectItem(at: 0)
    }

    @objc func levelChanged() {
        let l = Level(rawValue: max(0, levelSeg.selectedSegment)) ?? .beginner
        stage.level = l; defaults.set(l.rawValue, forKey: "level")
        stage.resetHold(); updateBand()
    }

    // MARK: session

    @objc func toggleSession() { session == nil ? startSession() : endSession(say: true) }

    func startSession() {
        let all = builtin + saved
        guard !all.isEmpty else { stage.toast("NO POSES FOUND"); return }
        session = all; sessionIndex = 0
        setTitle(sessionButton, "3  STOP SESSION"); skipButton.isHidden = false
        beginPose()
    }

    func endSession(say: Bool = false) {
        guard session != nil else { return }
        session = nil
        stage.band = nil
        setTitle(sessionButton, "3  START SESSION"); skipButton.isHidden = true
        Voice.shared.stop()
        if say { stage.toast("SESSION STOPPED") }
        stage.needsDisplay = true
    }

    func beginPose() {
        guard let s = session else { return }
        let n = s[sessionIndex]
        setTarget(n)
        updateBand()
        let spoken = (n.speak ?? n.name) + ". " + n.cues.joined(separator: " ")
        Voice.shared.speak(spoken)
    }

    func updateBand() {
        guard let s = session else { return }
        let n = s[sessionIndex]
        stage.band = ("POSE \(sessionIndex + 1) OF \(s.count)  ·  \(n.name.uppercased())  ·  \(stage.level.title)  ·  HOLD GREEN \(Int(stage.level.hold)) S",
                      n.cues.isEmpty ? "Match the white skeleton with yours." : n.cues.joined(separator: "  "))
        needsLayout = true; stage.needsDisplay = true
    }

    @objc func skip() { advance() }

    func advance() {
        guard let s = session else { return }
        if sessionIndex + 1 < s.count { sessionIndex += 1; beginPose() }
        else {
            endSession()
            stage.toast("SESSION COMPLETE")
            Voice.shared.speak("Session complete. Well done.")
        }
    }

    func achieved() {
        if soundSw.isOn { NSSound(named: "Glass")?.play() }
        guard session != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.advance() }
    }

    // MARK: settings

    @objc func showSettings() {
        refreshSettings()
        settingsPopover.show(relativeTo: controls.bounds, of: controls, preferredEdge: .minY)
    }

    func refreshSettings() {
        settingsText.stringValue = """
        SKELETON (MANTRA) v\(VERSION)
        CAMERA: \(stage.cameraName.isEmpty ? "none" : stage.cameraName) \(slots[0].formatText)
        LEVEL: \(stage.level.title)  green \(Int(stage.level.green))°, yellow \(Int(stage.level.yellow))°, hold \(Int(stage.level.hold)) s
        VOICE LAST USED: \(Voice.shared.lastUsed)
        VOICE IF THE MANTRA VOICE IS DOWN: \(Voice.shared.fallbackName)
        POSES FOLDER: \(Store.dir.path)
        \(multiSettings())
        """
    }
}
