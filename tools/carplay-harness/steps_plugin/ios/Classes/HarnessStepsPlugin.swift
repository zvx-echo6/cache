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
/// - `org.example.carharness.roll`: while guiding, five positions a second apart along the road, as a moving vehicle
///   gives them, so the marker's glide can be seen.
/// - `org.example.carharness.climb`: while guiding, the recorded trip that has a climb ahead.
/// - `org.example.carharness.phoneon` and `.phoneoff`: the stand-in Dart side says in its trip that the phone's drive screen
///   is showing, or no longer (`overlay.phoneDrive`), as the phone will. `.phoneflip`: showing for one second and then not,
///   timed by the stand-in Dart side.
/// - `org.example.carharness.promptshort`, `.promptnone` and `.promptnormal`: the stand-in Dart side asks the car side how a
///   spoken prompt may be given, as the phone's voice does before each prompt, and says the answer. For the first two the
///   car side is first told to answer as iOS would during a call, or while Siri listens (no call can be made in the
///   Simulator); for the last it reads the system's own style again.
/// - `org.example.carharness.nosaved` and `.saved`: the stand-in Dart side has no saved places, or has its recorded ones
///   again, and says that they changed.
/// - `org.example.carharness.day` and `.night`: the car scene is told that the car switched its day or night setting, through
///   the call CarPlay itself makes (`contentStyleDidChange`). The Simulator's car sits in its dark setting and has no switch a
///   script can reach; the app's reaction to the call is the product's own (the map follows the phone's theme, not this).
///   Apple's bars and buttons do not change with it.
/// - `org.example.carharness.theme_dark`, `.theme_light`, `.theme_parchment` and `.theme_tactical`: the stand-in Dart side
///   changes the phone's chosen theme, as the phone does: the car is told to load its style again and the trip goes out with
///   the theme's palette. `.themeburst`: five theme changes a tenth of a second apart, ending in Tactical, timed there.
public class HarnessStepsPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?
  /// What is passed on to the stand-in Dart side as it is.
  private static let toDart: [String] = [
    "next", "nosaved", "saved", "drive", "roll", "climb", "phoneon", "phoneoff", "phoneflip",
    "theme_dark", "theme_light", "theme_parchment", "theme_tactical", "themeburst",
  ]

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
    let names: [String] = (toDart + ["day", "night"] + Array(promptCodes.keys)).map { "org.example.carharness." + $0 }
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

  /// The audio session's codes for a short prompt and for none ('shrt', 'none'); nothing for the system's own.
  private static let promptCodes: [String: UInt?] = ["promptshort": 0x7368_7274, "promptnone": 0x6E6F_6E65, "promptnormal": nil]

  private static func told(_ name: String) {
    let word: String = name.components(separatedBy: ".").last ?? ""
    if let code = promptCodes[word] {
      // The product's CarPrompts, reached by its Objective-C name: this plugin is not part of the app's module.
      let prompts: NSObjectProtocol? = NSClassFromString("CarPrompts").flatMap { ($0 as AnyObject) as? NSObjectProtocol }
      let shared = prompts?.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject
      shared?.setValue(code.map { NSNumber(value: $0) }, forKey: "codeForTests")
      NSLog("%@", "harness steps: the car side answers prompts with \(code == nil ? "the system's own style" : "the style the job named") (\(shared == nil ? "CarPrompts not found" : "set"))")
      channel?.invokeMethod("prompt", arguments: nil)
      return
    }
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
