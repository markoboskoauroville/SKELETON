// Store.swift: the starter poses (poses.json in the app) and the user's saved poses (JSON + thumbnail on disk).
import AppKit

enum Store {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skeleton (Mantra)/poses", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func builtin() -> [NamedPose] {
        guard let u = Bundle.main.url(forResource: "poses", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([SavedPose].self, from: d) else { return [] }
        return list.map { $0.named() }
    }

    struct Sequence: Codable { var id: String; var name: String; var poses: [String] }

    /// Ready sequences (data/sequences.json): a name and the ids of starter poses, in order (a pose may come twice).
    static func sequences() -> [Sequence] {
        guard let u = Bundle.main.url(forResource: "sequences", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([Sequence].self, from: d) else { return [] }
        return list
    }

    static func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }

    static func save(_ n: NamedPose) {
        let base = dir.appendingPathComponent(safe(n.name))
        if let d = try? JSONEncoder().encode(SavedPose.from(n)) { try? d.write(to: base.appendingPathExtension("json")) }
        if let t = n.thumb {
            let rep = NSBitmapImageRep(cgImage: t)
            if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpg.write(to: base.appendingPathExtension("jpg"))
            }
        }
    }

    static func saved() -> [NamedPose] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let js = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [NamedPose] = []
        for u in js {
            guard let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode(SavedPose.self, from: d) else { continue }
            var n = s.named()
            let jpg = u.deletingPathExtension().appendingPathExtension("jpg")
            if let img = NSImage(contentsOf: jpg) { n.thumb = img.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            out.append(n)
        }
        return out
    }
}
