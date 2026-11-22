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

/// What becomes of the audio session once the style has been read with it active. Apple's CarPlay guide: the session is set
/// active only when a prompt is ready to play, the prompt style is checked just before each prompt, and the session is let go
/// when the prompt is done. Before, the style was read from a session that was not active and the phone's voice was left to
/// make it active by itself while it spoke.
enum CarPromptSession: Equatable {
  /// Kept active for the phone's voice, which speaks next and lets it go when it finishes (flutter_tts); if the voice never
  /// does, the car side lets it go after `CarPromptHold.seconds`.
  case heldForVoice
  /// Kept active while the tone plays, let go when it ends.
  case heldForTone
  /// Let go at once: nothing plays.
  case letGo

  init(_ style: CarPromptStyle) {
    switch style {
    case .spoken: self = .heldForVoice
    case .tone: self = .heldForTone
    case .silent: self = .letGo
    }
  }
}

/// How long the car side waits, after a spoken prompt was answered, before it lets the session go itself. Only a safety: the
/// session is let go as soon as the phone's voice says it has said its prompts (`promptDone`). It is the time the prompt takes
/// at the guidance rate (about 14 letters a second, with 2 s to start) and 10 s more; at most 30 seconds.
enum CarPromptHold {
  static func seconds(characters: Int) -> Double {
    min(30, 12 + 0.08 * Double(max(0, characters)))
  }
}

/// When the phone's voice has said its prompts, the session is let go, unless the tone is playing (its own end lets it go).
enum CarPromptDone {
  static func letsGo(tonePlaying: Bool) -> Bool { !tonePlaying }
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
/// prompt, lowering other audio and interrupting spoken audio). As Apple's CarPlay guide asks of navigation prompts, it is made
/// active when a prompt is ready to play, the style is read then, and the session is let go when the prompt is done, telling
/// the other apps (CarPromptSession).
@objc(CarPrompts)
final class CarPrompts: NSObject, AVAudioPlayerDelegate {
  @objc static let shared = CarPrompts()
  private static let log = Logger(subsystem: "co.cache.car", category: "prompts")

  /// For the tests in the Simulator, where no call can be made and no Siri asked: a style code to answer with in place of
  /// the system's. Nil, as it always is in the app itself: the system's.
  @objc dynamic var codeForTests: NSNumber?
  private var player: AVAudioPlayer?
  /// Lets the session go if the phone's voice never does (CarPromptHold).
  private var hold: DispatchWorkItem?

  /// Takes the car link's two prompt hooks. Called where the link is attached to the engine.
  func start() {
    CarLink.shared.onPrompt = { [weak self] text in self?.asked(text) }
    CarLink.shared.onPromptStop = { [weak self] in self?.stopped() }
    CarLink.shared.onPromptDone = { [weak self] in self?.voiceDone() }
    // The three codes this file knows are the system's own.
    let known = CarPromptStyle(code: AVAudioSession.PromptStyle.normal.rawValue) == .spoken
      && CarPromptStyle(code: AVAudioSession.PromptStyle.short.rawValue) == .tone
      && CarPromptStyle(code: AVAudioSession.PromptStyle.none.rawValue) == .silent
    Self.log.info("car prompts: ready, the system's three style codes are the known ones: \(known, privacy: .public)")
    // Another app taking the audio (an assistant, a call) interrupts this session. Nothing is resumed here: the next prompt
    // makes the session active again (asked), and the phone's voice clears itself if it was left paused (FlutterTtsSpeaker
    // in lib/nav/speaker.dart). The lines say when it happened, for a drive's log.
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      self?.interrupted(note)
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
      let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
      Self.log.info("car prompts: the audio route changed (reason \(raw, privacy: .public))")
    })
  }

  private var observers: [NSObjectProtocol] = []

  private func interrupted(_ note: Notification) {
    let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 99
    if raw == AVAudioSession.InterruptionType.began.rawValue {
      // A tone cut by it is let go with the session; the held time for the voice is not needed any more.
      hold?.cancel()
      hold = nil
      player?.stop()
      player = nil
      Self.log.info("car prompts: the audio session was interrupted by other audio; the next prompt makes it active again")
    } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
      let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
      let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
      Self.log.info("car prompts: the interruption ended (the system says resume: \(resume, privacy: .public))")
    }
  }

  private func style(_ session: AVAudioSession) -> CarPromptStyle {
    CarPromptStyle(code: codeForTests?.uintValue ?? session.promptStyle.rawValue)
  }

  private func asked(_ text: String) -> String {
    // The microphone is open for a search by voice (CarListen.swift): the audio session is its, and is not touched. The answer
    // is the one iOS gives while something listens: no prompt (the phone's voice stays quiet; a tone is not played either).
    if CarListening.active {
      Self.log.info("car prompts: asked while the car listens, no prompt is given and the audio session is left alone")
      return CarPromptStyle.silent.answer
    }
    let session = AVAudioSession.sharedInstance()
    // The style is the system's hint to a session in the voice prompt mode. The phone's voice sets that up when it first
    // speaks, which is after this question the first time: the same set-up is made here if it is not there yet.
    if session.category != .playback || session.mode != .voicePrompt {
      try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }
    let idle = style(session)
    // A prompt is ready to play: the session is made active now, and the style read again from the live session. That one
    // decides. The style read before is only logged, so a drive's log shows whether the two differ.
    var made = "made active"
    do {
      try session.setActive(true)
    } catch {
      made = "not made active (\(error.localizedDescription))"
    }
    let live = style(session)
    let front = PhoneWindow.shared.visible ? "the phone's window in front" : "the phone's window not in front"
    // No words of the prompt in the log (roads, places).
    Self.log.info("car prompts: asked with \(front, privacy: .public), the session \(made, privacy: .public), the style before \(idle.answer, privacy: .public), the answer is \(live.answer, privacy: .public)")
    hold?.cancel()
    hold = nil
    switch CarPromptSession(live) {
    case .heldForVoice:
      let item = DispatchWorkItem { [weak self] in self?.holdEnded() }
      hold = item
      DispatchQueue.main.asyncAfter(deadline: .now() + CarPromptHold.seconds(characters: text.count), execute: item)
    case .heldForTone:
      playTone(session)
    case .letGo:
      release()
    }
    return live.answer
  }

  /// The phone's voice did not let the session go in time (it never spoke, or it was stopped, which does not let it go): it
  /// is let go here. Not while the tone plays: its end lets it go.
  private func holdEnded() {
    hold = nil
    guard player == nil else { return }
    release()
    Self.log.info("car prompts: the session held for the phone's voice is let go")
  }

  /// The phone's voice has said every prompt it was given: the session held for it is let go now, telling the other apps, so
  /// their sound comes back as the prompt ends.
  private func voiceDone() {
    hold?.cancel()
    hold = nil
    guard CarPromptDone.letsGo(tonePlaying: player != nil) else { return }
    release()
    Self.log.info("car prompts: the phone's voice finished, the audio session is let go")
  }

  /// Dart stopped the prompts (the voice switched off, the route ended): the tone stops and the session is let go.
  private func stopped() {
    hold?.cancel()
    hold = nil
    player?.stop()
    release()
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
    // Listening has the session (CarListen.swift) and lets it go itself.
    if CarListening.active { return }
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
