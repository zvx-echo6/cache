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
/// - `org.example.carharness.day` and `.night`: the car scene is told that the car switched its day or night setting, through
///   the call CarPlay itself makes (`contentStyleDidChange`). The Simulator's car sits in its dark setting and has no switch a
///   script can reach; the app's reaction to the call is the product's own. Apple's bars and buttons do not change with it.
public class HarnessStepsPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "harness/steps", binaryMessenger: registrar.messenger())
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let names: [String] = ["org.example.carharness.next", "org.example.carharness.day", "org.example.carharness.night"]
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
    if name.hasSuffix(".next") {
      channel?.invokeMethod("next", arguments: nil)
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
