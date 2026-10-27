import Foundation
import WebKit
import Darwin

// Compile the exact rules exported by the Dart reader test with Apple's engine.
// Dart's regular-expression implementation accepts syntax WebKit rejects.
guard CommandLine.arguments.count == 2 else {
  fputs("usage: reader_rules_test.swift rules.json\n", stderr)
  exit(2)
}
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-reader-rules-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
guard let store = WKContentRuleListStore(url: root) else {
  try? FileManager.default.removeItem(at: root)
  fputs("Could not create the WebKit rule store\n", stderr)
  exit(1)
}
let identifier = "CacheOfflineReader-" + UUID().uuidString
var finished = false
var failure: String?
store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { rules, error in
  if let error = error {
    failure = "WebKit rejected the reader rules: \(error)"
    finished = true
  } else if rules == nil {
    failure = "WebKit returned no compiled reader rules"
    finished = true
  } else {
    store.removeContentRuleList(forIdentifier: identifier) { error in
      if let error = error { failure = "Could not remove test rules: \(error)" }
      finished = true
    }
  }
}
let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
try? FileManager.default.removeItem(at: root)
if !finished { failure = "WebKit reader-rule compilation timed out" }
if let failure = failure {
  fputs(failure + "\n", stderr)
  exit(1)
}
print("WebKit compiled the exact offline reader rules successfully")