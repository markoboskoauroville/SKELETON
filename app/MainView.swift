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

final class MainView: NSView, NSMenuDelegate {
    override var isFlipped: Bool { true }
    let stage = StageView()
    let controls = NSView()
    let camera = CameraController()
    var devices: [AVCaptureDevice] = []
    var device: AVCaptureDevice?
    let defaults = UserDefaults.standard

    let cameraPopup = NSPopUpButton()
    let savedPopup = NSPopUpButton()
    let levelSeg = NSSegmentedControl(labels: Level.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    var mirrorSw: SwitchRow!, anglesSw: SwitchRow!, onlySw: SwitchRow!, soundSw: SwitchRow!, voiceSw: SwitchRow!
    let permsButton = NSButton()
    let sessionButton = NSButton()
    let skipButton = NSButton()
    let titleLabel = NSTextField(labelWithString: "")

    var builtin: [NamedPose] = []
    var saved: [NamedPose] = []
    var session: [NamedPose]?
    var sessionIndex = 0
    var lastMove = Date()
    var openMenus = 0
    var pendingCamera: String?
    var authorized = false
    let settingsPopover = NSPopover()
    let settingsText = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(stage)
        buildControls()
        addSubview(controls)
        stage.onDropURL = { [weak self] in self?.loadPhoto($0) }
        stage.onAchieved = { [weak self] in self?.achieved() }
        camera.onFrame = { [weak self] img, size, poses in self?.stage.update(image: img, size: size, poses: poses) }
        Voice.shared.onChange = { [weak self] in self?.refreshSettings() }
        builtin = Store.builtin()
        refreshSaved()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: .AVCaptureDeviceWasConnected, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: .AVCaptureDeviceWasDisconnected, object: nil)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]) { [weak self] e in
            self?.wake(); return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            self?.window?.toggleFullScreen(nil)
            return nil
        }
        checkPermission(request: true)
        reloadDevices()
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
        setTitle(sessionButton, "③ START SESSION")
        skipButton.isBordered = false; skipButton.target = self; skipButton.action = #selector(skip)
        setTitle(skipButton, "NEXT POSE"); skipButton.isHidden = true
        let r2 = row([button("① LOAD POSE PHOTO", #selector(chooseFile)), button("② FREEZE MY POSE", #selector(freeze)), sessionButton, skipButton])

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

        let col = NSStackView(views: [r0, r1, r2, r3])
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
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 190))
        settingsText.frame = NSRect(x: 15, y: 10, width: 420, height: 170)
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
        stage.frame = bounds
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
        devices = CameraController.devices()
        cameraPopup.removeAllItems()
        for d in devices { cameraPopup.addItem(withTitle: d.localizedName) }
        if devices.isEmpty { cameraPopup.addItem(withTitle: "NO CAMERA"); stage.cameraName = ""; return }
        var pick: AVCaptureDevice?
        if let name = pendingCamera?.lowercased() {
            pick = devices.first { $0.localizedName.lowercased().contains(name) || $0.uniqueID.lowercased() == name }
        }
        if pick == nil, let cur = device { pick = devices.first { $0.uniqueID == cur.uniqueID } }
        if pick == nil, let id = defaults.string(forKey: "camera") { pick = devices.first { $0.uniqueID == id } }
        if pick == nil { pick = devices.first }
        if let p = pick {
            let changed = device?.uniqueID != p.uniqueID
            if let i = devices.firstIndex(where: { $0.uniqueID == p.uniqueID }) { cameraPopup.selectItem(at: i) }
            if changed || pendingCamera != nil { select(p) }
            pendingCamera = nil
        }
    }

    @objc func cameraChosen() {
        let i = cameraPopup.indexOfSelectedItem
        guard i >= 0, i < devices.count else { return }
        select(devices[i])
    }

    func select(_ d: AVCaptureDevice) {
        device = d
        defaults.set(d.uniqueID, forKey: "camera")
        let m = defaults.object(forKey: "mirror." + d.uniqueID) as? Bool ?? d.localizedName.contains("FaceTime")
        mirrorSw.isOn = m; stage.mirror = m
        stage.cameraName = d.localizedName
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        camera.start(d) { [weak self] in self?.refreshSettings() }
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
        setTitle(sessionButton, "③ STOP SESSION"); skipButton.isHidden = false
        beginPose()
    }

    func endSession(say: Bool = false) {
        guard session != nil else { return }
        session = nil
        stage.band = nil
        setTitle(sessionButton, "③ START SESSION"); skipButton.isHidden = true
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
        CAMERA: \(stage.cameraName.isEmpty ? "none" : stage.cameraName) \(camera.formatText)
        LEVEL: \(stage.level.title)  green \(Int(stage.level.green))°, yellow \(Int(stage.level.yellow))°, hold \(Int(stage.level.hold)) s
        VOICE LAST USED: \(Voice.shared.lastUsed)
        VOICE IF THE MANTRA VOICE IS DOWN: \(Voice.shared.fallbackName)
        POSES FOLDER: \(Store.dir.path)
        """
    }
}
