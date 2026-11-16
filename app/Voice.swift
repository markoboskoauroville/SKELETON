// Voice.swift: the pose name and its cues are spoken through Marko's voice API (MANTRA_VOICE, 127.0.0.1:8837, POST /speak).
// When it does not answer, the best voice installed on this Mac speaks instead (AVSpeechSynthesizer: premium, then
// enhanced, then default; English, en-GB / en-US first). Never a second TTS server.
import AVFoundation
import Foundation

final class Voice: NSObject {
    static let shared = Voice()
    static let api = "http://127.0.0.1:8837"
    var enabled = true
    private(set) var lastUsed = "not used yet"
    var onChange: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var remoteSpeaking = false

    static func bestMacVoice() -> AVSpeechSynthesisVoice? {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let q = v.quality.rawValue * 10
            let l = v.language == "en-GB" ? 2 : (v.language == "en-US" ? 1 : 0)
            return q + l
        }
        return en.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }

    var fallbackName: String {
        guard let v = Voice.bestMacVoice() else { return "none" }
        return "\(v.name) (\(Voice.qualityName(v)), \(v.language))"
    }

    private func remoteUp() -> Bool {
        guard let u = URL(string: Voice.api + "/health") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 0.8
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200, d != nil { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.2)
        return ok
    }

    func speak(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.remoteUp(), let u = URL(string: Voice.api + "/speak") {
                var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 5
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
                self.remoteSpeaking = true
                self.set("the Mantra voice (127.0.0.1:8837)")
                URLSession.shared.dataTask(with: r).resume()
            } else {
                DispatchQueue.main.async { self.speakLocal(text) }
            }
        }
    }

    private func speakLocal(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.46
        if let v = Voice.bestMacVoice() { u.voice = v }
        set("Mac voice \(fallbackName); the Mantra voice did not answer")
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if remoteSpeaking, let u = URL(string: Voice.api + "/speak/stop") {
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 1
            URLSession.shared.dataTask(with: r).resume()
            remoteSpeaking = false
        }
    }

    private func set(_ s: String) {
        DispatchQueue.main.async { self.lastUsed = s; self.onChange?() }
    }
}
