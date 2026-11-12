import CarPlay
import Flutter
import UIKit

/// CarPlay harness only (tools/carplay-harness): never a part of the app.
///
/// The harness app is the product's own app delegate and car scene around a stand-in Dart side. Two things the job on the
/// Mac needs from it cannot be had from outside, and neither belongs in the product, so they live here, in a plugin of the
/// harness app alone. The job asks with a Darwin notification (`xcrun simctl spawn <device> notifyutil -p <name>`):
///
/// - `org.example.carharness.next`: the stand-in Dart side moves on to its next recorded trip (channel `harness/steps`).
/// - `org.example.carharness.drive`: while guiding, the stand-in Dart side moves on along its recorded drive (nearer the
///   turn, the next turn, looking for a new route, arrived, and round again).
/// - `org.example.carharness.nosaved` and `.saved`: the stand-in Dart side has no saved places, or has its recorded ones
///   again, and says that they changed.
/// - `org.example.carharness.day` and `.night`: the car scene is told that the car switched its day or night setting, through
///   the call CarPlay itself makes (`contentStyleDidChange`). The Simulator's car sits in its dark setting and has no switch a
///   script can reach; the app's reaction to the call is the product's own. Apple's bars and buttons do not change with it.
public class HarnessStepsPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?
  /// What is passed on to the stand-in Dart side as it is.
  private static let toDart: [String] = ["next", "nosaved", "saved", "drive"]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let steps = FlutterMethodChannel(name: "harness/steps", binaryMessenger: registrar.messenger())
    // The stand-in Dart side says what happened to it in the app's log, where the job reads it.
    steps.setMethodCallHandler { call, result in
      if call.method == "say", let text = call.arguments as? String {
        NSLog("%@", "harness steps: " + text)
      }
      result(nil)
    }
    channel = steps
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let names: [String] = (toDart + ["day", "night"]).map { "org.example.carharness." + $0 }
    for name in names {
      CFNotificationCenterAddObserver(
        center, nil,
        { _, _, posted, _, _ in
          let told: String = posted.map { $0.rawValue as String } ?? ""
          DispatchQueue.main.async { HarnessStepsPlugin.told(told) }
        },
        name as CFString, nil, .deliverImmediately)
    }
    NSLog("%@", "harness steps: listening for the job's notifications")
  }

  private static func told(_ name: String) {
    let word: String = name.components(separatedBy: ".").last ?? ""
    if toDart.contains(word) {
      channel?.invokeMethod(word, arguments: nil)
      return
    }
    let style: UIUserInterfaceStyle = name.hasSuffix(".day") ? .light : .dark
    var scenes = 0
    for scene in UIApplication.shared.connectedScenes {
      guard let car = scene as? CPTemplateApplicationScene else { continue }
      guard let delegate = car.delegate as? CPTemplateApplicationSceneDelegate else { continue }
      delegate.contentStyleDidChange?(style)
      scenes += 1
    }
    let setting: String = style == .light ? "light" : "dark"
    NSLog("%@", "harness steps: told \(scenes) car scene(s) that the car's setting is now \(setting)")
  }
}
