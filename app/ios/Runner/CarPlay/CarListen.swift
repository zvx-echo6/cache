import Foundation

/// Voice search on the car screen: a microphone button on the map's bar, CarPlay's voice control template while the phone
/// listens, the phone's on-device speech recognizer, and the words it heard going into the car's search as if they were typed
/// (CarTemplates.swift). The first half of this file has no iOS frameworks in it, so its rules are tested on a Mac
/// (tools/carplay-harness/tests); the iOS parts (the audio session, the recognizer, the permission status) are below it.
///
/// Apple allows recording in CarPlay only together with the voice control template, so the microphone is open only while that
/// template is up: the audio session is made active when listening begins and let go, telling the other apps, the moment
/// listening ends, whichever way it ends (CarListenSession). The car never asks for a permission: the button is shown only when
/// the microphone and speech recognition were both allowed already, and a recognizer that works on the device is there
/// (CarListenAccess). The car says nothing about the phone.

/// The three words of the voice control template's states. The system's own Cancel is the template's.
enum CarListenWords {
  static let listening = "Listening"
  static let searching = "Searching"
  static let didntCatch = "Didn't catch that"
}

/// Whether the microphone button is shown: only when everything it needs is there already.
struct CarListenAccess: Equatable {
  var microphoneGranted: Bool
  var speechAuthorized: Bool
  var onDeviceRecognizer: Bool

  var showsButton: Bool { microphoneGranted && speechAuthorized && onDeviceRecognizer }
}

/// What the recognizer says: words so far, the final words, or that it could not go on.
enum CarListenResult: Equatable {
  case partial(String)
  case final(String)
  case failed
}

enum CarListenState: Equatable {
  case idle
  case listening
  case searching
  case didntCatch
}

/// While listening is on, the phone's spoken prompts (CarPrompts) leave the audio session alone and answer that none may be
/// given: the same answer iOS gives while something listens on the microphone.
enum CarListening {
  static var active = false
}

/// The audio session of listening. `begin` makes it active for recording, `end` lets it go and tells the other apps; `end` may
/// be called when it is not active and then does nothing.
protocol CarListenAudio: AnyObject {
  /// Called when something else took the audio (a call, Siri): listening is over.
  var onLost: (() -> Void)? { get set }
  func begin() throws
  func end()
}

protocol CarListenRecognizer: AnyObject {
  /// Starts listening and calls `handler` (on any queue) with what it hears.
  func start(_ handler: @escaping (CarListenResult) -> Void)
  /// No more sound is coming: the recognizer settles on what it has.
  func endAudio()
  func cancel()
}

/// One use of the microphone, from the tap to the end. It ends at the first of: the recognizer's final words (it ends on a
/// silence by itself), the cap, a failure, `cancel` (the template was left, or something took the audio). Whatever the end, the
/// audio is let go at once.
final class CarListenSession {
  /// The longest listening, in seconds.
  static let cap: TimeInterval = 8
  /// After the cap the recognizer is given this long to settle before what was heard so far is taken.
  static let grace: TimeInterval = 1.5
  /// How long "Didn't catch that" stays before the template goes.
  static let didntCatchFor: TimeInterval = 2

  private let audio: CarListenAudio
  private let recognizer: CarListenRecognizer
  private let cap: TimeInterval
  private let grace: TimeInterval
  private let didntCatchFor: TimeInterval
  private(set) var state: CarListenState = .idle
  /// Changes with every listening and every end: an answer meant for an earlier one can tell it is stale.
  private(set) var generation = 0
  private var heard = ""

  /// The state changed (always on the main queue).
  var onState: (CarListenState) -> Void = { _ in }
  /// The words to search for.
  var onText: (String) -> Void = { _ in }

  init(
    audio: CarListenAudio,
    recognizer: CarListenRecognizer,
    cap: TimeInterval = CarListenSession.cap,
    grace: TimeInterval = CarListenSession.grace,
    didntCatchFor: TimeInterval = CarListenSession.didntCatchFor
  ) {
    self.audio = audio
    self.recognizer = recognizer
    self.cap = cap
    self.grace = grace
    self.didntCatchFor = didntCatchFor
    audio.onLost = { [weak self] in self?.cancel() }
  }

  func begin() {
    guard state == .idle else { return }
    generation += 1
    let mine = generation
    heard = ""
    CarListening.active = true
    do {
      try audio.begin()
    } catch {
      audio.end()
      CarListening.active = false
      noWords(mine)
      return
    }
    state = .listening
    onState(.listening)
    recognizer.start { [weak self] result in
      DispatchQueue.main.async { self?.recognized(result, mine) }
    }
    after(cap, mine) { [weak self] in
      guard let self = self, self.state == .listening else { return }
      self.recognizer.endAudio()
      self.after(self.grace, mine) { [weak self] in
        guard let self = self else { return }
        self.finish(self.heard)
      }
    }
  }

  /// The template was left, or something took the audio: listening stops and nothing is searched.
  func cancel() {
    guard state != .idle else { return }
    generation += 1
    if state == .listening {
      recognizer.cancel()
      audio.end()
      CarListening.active = false
    }
    state = .idle
    onState(.idle)
  }

  /// The search for the words is over (its answer was shown, or it was dropped): ready for the next listening.
  func finished() {
    guard state == .searching else { return }
    state = .idle
    onState(.idle)
  }

  private func recognized(_ result: CarListenResult, _ mine: Int) {
    guard mine == generation, state == .listening else { return }
    switch result {
    case .partial(let text): heard = text
    case .final(let text): finish(text)
    case .failed: finish(nil)
    }
  }

  private func finish(_ text: String?) {
    guard state == .listening else { return }
    generation += 1
    let mine = generation
    recognizer.cancel()
    audio.end()
    CarListening.active = false
    let words = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if words.isEmpty {
      noWords(mine)
    } else {
      state = .searching
      onState(.searching)
      onText(words)
    }
  }

  private func noWords(_ mine: Int) {
    state = .didntCatch
    onState(.didntCatch)
    after(didntCatchFor, mine) { [weak self] in
      guard let self = self, self.state == .didntCatch else { return }
      self.state = .idle
      self.onState(.idle)
    }
  }

  private func after(_ seconds: TimeInterval, _ mine: Int, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self = self, mine == self.generation else { return }
      work()
    }
  }
}

// ---- stand-ins, for the Mac tests and for the harness's pictures (no microphone in either) ----------------------------------

/// What the harness gives the recognizer in place of a microphone.
struct CarListenTestSetup {
  /// The words "heard"; nil or blank is "Didn't catch that".
  var text: String?
  /// How long "Listening" stays before the words come.
  var listeningFor: TimeInterval
  /// How long "Searching" stays at least, so it can be pictured.
  var searchingFor: TimeInterval
  /// How long "Didn't catch that" stays.
  var didntCatchFor: TimeInterval
}

enum CarListen {
  /// Nil in the app itself. In the harness: the car's mic button shows and a fixed result is "heard" (no microphone, no audio
  /// session, no permissions asked).
  static var testSetup: CarListenTestSetup?
}

final class CarListenFakeAudio: CarListenAudio {
  var onLost: (() -> Void)?
  var begins = 0
  var ends = 0
  var failToBegin = false
  private(set) var active = false

  func begin() throws {
    if failToBegin { throw NSError(domain: "CarListenFakeAudio", code: 1) }
    begins += 1
    active = true
  }

  func end() {
    ends += 1
    active = false
  }
}

final class CarListenFakeRecognizer: CarListenRecognizer {
  var starts = 0
  var cancels = 0
  var audioEnds = 0
  /// What it says, in order, as soon as it is started (`later` seconds after, when set).
  var results: [CarListenResult] = []
  var later: TimeInterval = 0
  private var handler: ((CarListenResult) -> Void)?

  func start(_ handler: @escaping (CarListenResult) -> Void) {
    starts += 1
    self.handler = handler
    let say = results
    DispatchQueue.main.asyncAfter(deadline: .now() + later) { [weak self] in
      guard let self = self, self.handler != nil else { return }
      for result in say { handler(result) }
    }
  }

  /// For a test that wants to speak by hand.
  func say(_ result: CarListenResult) { handler?(result) }
  func endAudio() { audioEnds += 1 }
  func cancel() {
    cancels += 1
    handler = nil
  }
}

#if os(iOS)
import AVFoundation
import Speech
import os

/// The microphone, from the audio session. Recording only while listening; no mode that keeps it open between uses. Other
/// audio is lowered while it listens (a navigation app's ducking), and the other apps are told when it lets go.
final class CarListenAudioSession: CarListenAudio {
  private static let log = Logger(subsystem: "co.cache.car", category: "listen")
  var onLost: (() -> Void)?
  private var active = false
  private var observer: NSObjectProtocol?

  func begin() throws {
    let session = AVAudioSession.sharedInstance()
    // Recording with the measurement mode (what speech recognition wants: no processing of the voice), lowering other audio.
    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try session.setActive(true)
    active = true
    observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 99
      guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
      Self.log.info("car listen: the audio session was interrupted, listening stops")
      self?.onLost?()
    }
    Self.log.info("car listen: the audio session is active for recording")
  }

  func end() {
    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    guard active else { return }
    active = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    Self.log.info("car listen: the audio session is let go")
  }
}

/// The phone's own recognizer, on the device only (requiresOnDeviceRecognition): the sound never leaves the phone.
final class CarListenSpeech: CarListenRecognizer {
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?

  static func onDeviceRecognizer() -> SFSpeechRecognizer? {
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition else { return nil }
    return recognizer
  }

  func start(_ handler: @escaping (CarListenResult) -> Void) {
    stop()
    guard let recognizer = Self.onDeviceRecognizer(), recognizer.isAvailable else {
      handler(.failed)
      return
    }
    self.recognizer = recognizer
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .search
    self.request = request
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
      request.append(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      stop()
      handler(.failed)
      return
    }
    task = recognizer.recognitionTask(with: request) { result, error in
      if let result = result {
        let text = result.bestTranscription.formattedString
        handler(result.isFinal ? .final(text) : .partial(text))
      } else if error != nil {
        handler(.failed)
      }
    }
  }

  func endAudio() {
    stopEngine()
    request?.endAudio()
  }

  func cancel() {
    stop()
  }

  private func stopEngine() {
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
  }

  private func stop() {
    stopEngine()
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
  }
}

extension CarListenAccess {
  /// What the phone has been allowed, read only: the car never asks.
  static func current() -> CarListenAccess {
    if CarListen.testSetup != nil {
      return CarListenAccess(microphoneGranted: true, speechAuthorized: true, onDeviceRecognizer: true)
    }
    let mic: Bool
    if #available(iOS 17.0, *) {
      mic = AVAudioApplication.shared.recordPermission == .granted
    } else {
      mic = AVAudioSession.sharedInstance().recordPermission == .granted
    }
    return CarListenAccess(
      microphoneGranted: mic,
      speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
      onDeviceRecognizer: CarListenSpeech.onDeviceRecognizer() != nil)
  }
}

extension CarListenSession {
  /// The session of the app: the real audio and recognizer, or the harness's stand-ins.
  static func make() -> CarListenSession {
    if let test = CarListen.testSetup {
      let recognizer = CarListenFakeRecognizer()
      recognizer.later = test.listeningFor
      recognizer.results = [.final(test.text ?? "")]
      return CarListenSession(audio: CarListenFakeAudio(), recognizer: recognizer, didntCatchFor: test.didntCatchFor)
    }
    return CarListenSession(audio: CarListenAudioSession(), recognizer: CarListenSpeech())
  }
}
#endif
