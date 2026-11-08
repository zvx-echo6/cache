import Flutter
import ImageIO
import UIKit
import Vision

/// Text recognition with Apple Vision, one page at a time on one background queue (a page image is about 34 MB decoded at
/// 300 dpi; one at a time keeps memory flat). Answers `info`, `recognize` and `memory` on co.cache/cache_ocr.
public class CacheOcrPlugin: NSObject, FlutterPlugin {
  /// Goes into book.ocr; lowercase and stable.
  static let engine = "apple-vision"
  /// English first. Other languages are added here (see the package README); the version then names them.
  static let languages = ["en-US"]

  private let queue = DispatchQueue(label: "co.cache.cache_ocr", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "co.cache/cache_ocr", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(CacheOcrPlugin(), channel: channel)
  }

  /// The Vision request revision, pinned so the same engine and version always mean the same recogniser: 3 from iOS 16 (the
  /// app's floor is 16.3), else 2.
  static var revision: Int {
    if #available(iOS 16.0, *) { return VNRecognizeTextRequestRevision3 }
    return VNRecognizeTextRequestRevision2
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      result(["engine": CacheOcrPlugin.engine, "version": String(CacheOcrPlugin.revision), "languages": CacheOcrPlugin.languages])
    case "memory":
      let m = CacheOcrPlugin.memory()
      result(["current_bytes": m.current, "peak_bytes": m.peak])
    case "recognize":
      let args = call.arguments as? [String: Any]
      let path = args?["path"] as? String ?? ""
      queue.async {
        let out = CacheOcrPlugin.recognize(path: path)
        DispatchQueue.main.async { result(out) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func recognize(path: String) -> Any {
    return autoreleasepool { () -> Any in
      guard FileManager.default.fileExists(atPath: path) else {
        return FlutterError(code: "no_file", message: "No image at \(path)", details: nil)
      }
      let before = memory()
      let t0 = DispatchTime.now().uptimeNanoseconds
      // Decoded here, once, so the time to load the file is measured apart from the recognition.
      let opts = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts),
            let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      else {
        return FlutterError(code: "bad_image", message: "Not an image: \(path)", details: nil)
      }
      let t1 = DispatchTime.now().uptimeNanoseconds
      let request = VNRecognizeTextRequest()
      request.revision = revision
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = languages
      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      } catch {
        return FlutterError(code: "engine", message: "\(error)", details: nil)
      }
      let t2 = DispatchTime.now().uptimeNanoseconds
      let after = memory()
      // Vision's observations are lines; kept in the order Vision gives (top to bottom).
      var lines: [[String: Any]] = []
      for obs in request.results ?? [] {
        guard let best = obs.topCandidates(1).first else { continue }
        lines.append(["text": best.string, "confidence": Double(best.confidence)])
      }
      let stats: [String: Any] = [
        "decode_ms": Double(t1 - t0) / 1e6,
        "recognize_ms": Double(t2 - t1) / 1e6,
        "before_bytes": before.current,
        "after_bytes": after.current,
        "peak_bytes": after.peak,
      ]
      return ["lines": lines, "stats": stats]
    }
  }

  /// The process's physical footprint now and its peak (task_vm_info), in bytes.
  static func memory() -> (current: Int, peak: Int) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
  }
}
