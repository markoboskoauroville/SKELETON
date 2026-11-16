// CalibStore.swift: calibrations kept per camera unique ID in ~/Library/Application Support/Skeleton (Mantra)/calibration.
import Foundation

struct StoredIntrinsics: Codable {
    var uid: String
    var name: String
    var K: Intrinsics
    var rms: Double
    var views: Int
    var date: String
}

struct StoredExtrinsics: Codable {
    var uidA: String
    var uid: String
    var E: Extrinsics
    var spacingMm: Double
    var date: String
}

enum CalibStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skeleton (Mantra)/calibration", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    static func save(_ i: StoredIntrinsics) {
        if let d = try? JSONEncoder().encode(i) { try? d.write(to: dir.appendingPathComponent("intrinsics-" + safe(i.uid) + ".json")) }
    }
    static func loadIntrinsics(_ uid: String) -> StoredIntrinsics? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("intrinsics-" + safe(uid) + ".json")) else { return nil }
        return try? JSONDecoder().decode(StoredIntrinsics.self, from: d)
    }
    static func save(_ e: StoredExtrinsics) {
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: dir.appendingPathComponent("extrinsics-" + safe(e.uidA) + "-" + safe(e.uid) + ".json")) }
    }
    static func loadExtrinsics(a: String, b: String) -> StoredExtrinsics? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("extrinsics-" + safe(a) + "-" + safe(b) + ".json")) else { return nil }
        return try? JSONDecoder().decode(StoredExtrinsics.self, from: d)
    }
}
