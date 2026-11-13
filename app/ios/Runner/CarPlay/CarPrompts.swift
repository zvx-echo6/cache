import Foundation

/// How a spoken prompt may be given at this moment. iOS says so through the audio session's prompt style, which a navigation
/// app reads before each prompt: a spoken prompt is fine; only a short one without words (a voice call is on, Siri is up but
/// not listening, a voicemail plays); or none at all (something is listening on the microphone).
///
/// The phone's voice is Dart's (lib/nav/speaker.dart). Before each prompt Dart asks the car side (CarAwareSpeaker in
/// lib/car/car_bridge.dart), and the answer here decides: Dart speaks for "normal" only; for "short" the car side plays a tone
/// itself (CarPrompts below).
enum CarPromptStyle: String {
  case spoken = "normal"
  case tone = "short"
  case silent = "none"

  /// From the audio session's own code for the style (AVAudioSession.PromptStyle's raw value, the four letters 'nrml', 'shrt'
  /// and 'none' as a number). A code that is none of the three is taken as spoken: the phone then speaks, as it does with no
  /// car attached.
  init(code: UInt) {
    switch code {
    case 0x6E6F_6E65: self = .silent
    case 0x7368_7274: self = .tone
    default: self = .spoken
    }
  }

  /// What Dart is told.
  var answer: String { rawValue }
}

/// The short prompt without words: one soft note, as sound samples. Pure sums, so the Mac tests can hold its length and
/// loudness: 16-bit samples of a sine at `hertz`, rising over the first hundredth of a second and dying away to the end.
enum CarPromptTone {
  static let rate: Double = 44100
  static let hertz: Double = 880
  static let seconds: Double = 0.28
  static let loudest: Double = 0.45

  static func samples() -> [Int16] {
    let count = Int(rate * seconds)
    var out: [Int16] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      let t = Double(i) / rate
      let rise: Double = min(1, t / 0.01)
      let fall: Double = pow(1 - t / seconds, 2)
      let value: Double = sin(2 * Double.pi * hertz * t) * loudest * rise * fall
      out.append(Int16(value * 32767))
    }
    return out
  }

  /// The samples as a WAV file in memory (one channel, 16 bits), which the system's player takes.
  static func wav() -> Data {
    let pcm = samples()
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(pcm.count * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    put32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    put32(16)
    put16(1)
    put16(1)
    put32(UInt32(rate))
    put32(UInt32(rate) * 2)
    put16(2)
    put16(16)
    data.append(contentsOf: Array("data".utf8))
    put32(bytes)
    for sample in pcm { put16(UInt16(bitPattern: sample)) }
    return data
  }
}

#if os(iOS)
import AVFoundation
import os

/// Answers Dart before each spoken prompt (CarLink.onPrompt) with what iOS says about prompts at that moment, and plays the
/// tone when iOS asks for a short prompt without words. The audio session is the one the phone's voice uses (playback, voice
/// prompt, lowering other audio and interrupting spoken audio): for the tone it is made active only while the tone plays and
/// let go straight after, telling the other apps, as Apple asks of navigation prompts.
@objc(CarPrompts)
final class CarPrompts: NSObject, AVAudioPlayerDelegate {
  @objc static let shared = CarPrompts()
  private static let log = Logger(subsystem: "co.cache.car", category: "prompts")

  /// For the tests in the Simulator, where no call can be made and no Siri asked: a style code to answer with in place of
  /// the system's. Nil, as it always is in the app itself: the system's.
  @objc dynamic var codeForTests: NSNumber?
  private var player: AVAudioPlayer?

  /// Takes the car link's two prompt hooks. Called where the link is attached to the engine.
  func start() {
    CarLink.shared.onPrompt = { [weak self] _ in self?.asked() }
    CarLink.shared.onPromptStop = { [weak self] in self?.stopTone() }
    // The three codes this file knows are the system's own.
    let known = CarPromptStyle(code: AVAudioSession.PromptStyle.normal.rawValue) == .spoken
      && CarPromptStyle(code: AVAudioSession.PromptStyle.short.rawValue) == .tone
      && CarPromptStyle(code: AVAudioSession.PromptStyle.none.rawValue) == .silent
    Self.log.info("car prompts: ready, the system's three style codes are the known ones: \(known, privacy: .public)")
  }

  private func asked() -> String {
    let session = AVAudioSession.sharedInstance()
    // The style is the system's hint to a session in the voice prompt mode. The phone's voice sets that up when it first
    // speaks, which is after this question the first time: the same set-up is made here if it is not there yet.
    if session.mode != .voicePrompt {
      try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }
    let style = CarPromptStyle(code: codeForTests?.uintValue ?? session.promptStyle.rawValue)
    // No words of the prompt in the log (roads, places).
    Self.log.info("car prompts: asked, the answer is \(style.answer, privacy: .public)")
    if style == .tone {
      playTone(session)
    }
    return style.answer
  }

  private func playTone(_ session: AVAudioSession) {
    stopTone()
    do {
      try session.setActive(true)
      let made = try AVAudioPlayer(data: CarPromptTone.wav())
      made.delegate = self
      player = made
      if made.play() {
        Self.log.info("car prompts: the tone plays")
      } else {
        Self.log.info("car prompts: the tone did not start")
        release()
      }
    } catch {
      Self.log.info("car prompts: the tone could not be played: \(error.localizedDescription, privacy: .public)")
      release()
    }
  }

  private func stopTone() {
    guard let playing = player else { return }
    playing.stop()
    release()
  }

  /// The audio session is let go, and the other apps are told so their sound comes back.
  private func release() {
    player = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if player === self.player {
      release()
      Self.log.info("car prompts: the tone ended, the audio session is let go")
    }
  }
}
#endif
