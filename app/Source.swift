// Source.swift: the camera-source abstraction (Marko, 16.11.2026: "Sony and phone through Iriun or two phones or any
// combination"). Anything that delivers frames can be one of the 1 to 3 views of Skeleton: an AVFoundation camera
// (AVCameraSource, Camera.swift), the Pixel through USB (Manual Camera, its own file), a network or file source.
//
// The contract:
//  - `onPixelBuffer` is called with each frame as a BGRA CVPixelBuffer and its HOST-CLOCK time in seconds
//    (CMTime seconds of the capture timestamp on the Mac's host clock; for a source that has only its own clock,
//    convert to the host clock on arrival, e.g. ProcessInfo.systemUptime, and say so in `clockNote`).
//    It may be called on any queue; the pipeline hops to its own.
//  - `start` is asynchronous and calls `completion(true)` when frames flow, `completion(false)` when it could not start.
//  - `intrinsics` is the lens model the source brings itself (nil = the user calibrates it with the board).
//  - `uniqueID` is stable between launches: calibrations are stored by it.
import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox

protocol FrameSource: AnyObject {
    var name: String { get }
    var uniqueID: String { get }
    var intrinsics: Intrinsics? { get }
    var formatText: String { get }
    var clockNote: String { get }
    var onPixelBuffer: ((CVPixelBuffer, Double) -> Void)? { get set }
    func start(completion: @escaping (Bool) -> Void)
    func stop()
}

func cgImage(from pb: CVPixelBuffer) -> CGImage? {
    var cg: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
    return cg
}

/// Mean luminance 0...255 of a BGRA buffer, sampled on a coarse grid (used for the flash-based sync).
func meanLuminance(_ pb: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, n = 0.0
    let sx = max(1, w / 48), sy = max(1, h / 27)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let o = y * bpr + x * 4
            sum += 0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2])
            n += 1
            x += sx
        }
        y += sy
    }
    return n > 0 ? sum / n : 0
}
