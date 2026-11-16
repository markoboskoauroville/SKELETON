// Tools.swift: the cleanup step between RECORD and RENDER MANNEQUIN (skelclean.py), the export for Claude and the import of
// Claude's answer (export_for_claude.py, import_from_claude.py). The scripts live in ~/Developer/SKELETON/cleanup/.
import AppKit

extension MainView {
    static var cleanupDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/SKELETON/cleanup") }

    func selectedRecording() -> URL? {
        refreshRecordings()
        guard !recordings.isEmpty else { stage.toast("NO RECORDING YET: PRESS RECORD (R)"); return nil }
        return recordings[max(0, min(recordings.count - 1, recPopup.indexOfSelectedItem))]
    }

    /// Runs /usr/bin/python3 with the script and arguments in the background; `done` gets the exit code and all its output.
    func runPython(_ script: String, _ args: [String], done: @escaping (Int32, String) -> Void) {
        let path = MainView.cleanupDir.appendingPathComponent(script).path
        guard FileManager.default.fileExists(atPath: path) else { stage.toast("\(script) IS NOT INSTALLED YET"); return }
        guard !toolBusy else { stage.toast("A TOOL IS STILL RUNNING"); return }
        toolBusy = true
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [path] + args
        p.standardOutput = pipe; p.standardError = pipe
        var out = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in out.append(h.availableData) }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            out.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let text = String(data: out, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.toolBusy = false; done(proc.terminationStatus, text) }
        }
        do { try p.run() } catch { toolBusy = false; stage.toast("COULD NOT START PYTHON") }
    }

    func lastLine(_ s: String) -> String {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.last ?? ""
    }

    @objc func presetChosen() { defaults.set(presetPopup.titleOfSelectedItem ?? "standard", forKey: "preset") }

    @objc func cleanPressed() {
        guard let rec = selectedRecording() else { return }
        let out = MainView.variant(rec, "clean")
        let report = out.deletingPathExtension().deletingPathExtension().appendingPathExtension("report.md")
        let preset = presetPopup.titleOfSelectedItem ?? "standard"
        stage.toast("CLEANING (\(preset.uppercased()))...")
        runPython("skelclean.py", [rec.path, "-o", out.path, "--preset", preset, "--report", report.path]) { code, text in
            if code == 0 {
                self.refreshRecordings()
                self.stage.toast("CLEANED: " + self.lastLine(text))
            } else { self.stage.toast("CLEAN FAILED: " + self.lastLine(text)) }
        }
    }

    @objc func openReport() {
        guard let rec = selectedRecording() else { return }
        let base = rec.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "")
        let r = rec.deletingLastPathComponent().appendingPathComponent(base + ".clean.report.md")
        if FileManager.default.fileExists(atPath: r.path) { NSWorkspace.shared.open(r) } else { stage.toast("NO REPORT YET: PRESS CLEAN") }
    }

    @objc func exportForClaude() {
        guard let rec = selectedRecording() else { return }
        let base = rec.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "")
        let out = rec.deletingLastPathComponent().appendingPathComponent(base + ".skelclaude.md")
        stage.toast("WRITING THE FILE FOR CLAUDE...")
        runPython("export_for_claude.py", [rec.path, "-o", out.path]) { code, text in
            if code == 0, FileManager.default.fileExists(atPath: out.path) {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                self.stage.toast("FOR CLAUDE: " + out.lastPathComponent)
            } else { self.stage.toast("EXPORT FAILED: " + self.lastLine(text)) }
        }
    }

    @objc func importClaude() {
        guard let rec = selectedRecording() else { return }
        let p = NSOpenPanel()
        p.message = "Choose Claude's answer (a Markdown, JSON or text file)"
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let reply = p.url else { return }
        let out = MainView.variant(rec, "claude")
        let base = rec.lastPathComponent.replacingOccurrences(of: ".skel.json", with: "")
        let report = rec.deletingLastPathComponent().appendingPathComponent(base + ".claude.report.md")
        stage.toast("CHECKING CLAUDE'S ANSWER...")
        runPython("import_from_claude.py", [rec.path, reply.path, "-o", out.path, "--report", report.path]) { code, text in
            if code == 0 {
                self.refreshRecordings()
                self.stage.toast("CLAUDE'S ANSWER APPLIED: " + self.lastLine(text))
            } else if code == 2 {
                let a = NSAlert()
                a.messageText = "Claude's answer was REJECTED"
                a.informativeText = String(text.prefix(1500))
                a.runModal()
            } else { self.stage.toast("IMPORT FAILED: " + self.lastLine(text)) }
        }
    }
}
