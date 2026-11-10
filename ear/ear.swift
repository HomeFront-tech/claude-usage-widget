// buddy-ear: the buddy's ears and voice (a helper for voice.lua)
//
// Listens on the default microphone, splits what it hears into utterances at the pauses,
// and writes each one down live with Apple's on-device dictation (macOS 26+). It also
// plays the buddy's speech, through the same audio engine with Apple's voice processing
// on, so the microphone never hears him (or anything else this Mac plays) while he talks.
// The recognizer only gets audio while someone is talking, so a quiet room costs next to
// nothing. Nothing is recorded or kept.
//
// One JSON object per line each way. Commands on stdin:
//   {"cmd":"listen","on":true}   {"cmd":"speak","id":1,"file":"/tmp/x.aiff"}   {"cmd":"stop"}   {"cmd":"quit"}
// Events on stdout:
//   ready, error(why, fatal), start(utt), words(utt, text), end(utt, text, split),
//   speaking(id, secs), spoken(id, cut), busy(on, app), note(what: something it put right
//   by itself, for the console), eof (--file only)
// An end with "split": true wasn't a pause: the talking went on past the utterance limit, so
// the next utterance carries on from it.
// usage: buddy-ear [--gap SECS] [--no-listen] [--file AUDIO]   (--file: read audio from a file, for tests)

import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech

let out = DispatchQueue(label: "ear.out")
func emit(_ ev: String, _ fields: [String: Any] = [:]) {
  var d = fields
  d["ev"] = ev
  guard let data = try? JSONSerialization.data(withJSONObject: d), let line = String(data: data, encoding: .utf8) else { return }
  out.sync { print(line); fflush(stdout) }
}
func fail(_ why: String) -> Never { emit("error", ["why": why, "fatal": true]); exit(1) }

var gap = 1.0
var filePath: String? = nil
var listenAtStart = true
do {
  var args = CommandLine.arguments.dropFirst()
  while let a = args.popFirst() {
    switch a {
    case "--gap": gap = max(0.3, Double(args.popFirst() ?? "") ?? 1.0)
    case "--file": filePath = args.popFirst()
    case "--no-listen": listenAtStart = false
    default: break
    }
  }
}

let work = DispatchQueue(label: "ear.work") // all listening state lives on this queue
let BLOCK = 0.08        // seconds of audio per pause-detection block
let PREROLL = 6         // blocks kept from before speech starts (about half a second)
// The transcriber costs more the longer one result runs, so long talking is cut into pieces:
let SOFT_UTTERANCE = 20.0 // after this long, a short dip between words ends the utterance
let SPLIT_QUIET = 0.24    // (that much quiet: three blocks)
let MAX_UTTERANCE = 30.0  // talking this long without even a dip ends it anyway
let TAIL = 6            // blocks still fed after an utterance: finalize waits for audio past its end
let CALM_AFTER = 1.5     // seconds voice processing stays on after a speech, for the next one to use
let RECOVER_TRIES = 4    // times a speech is started again after the audio engine stopped under it
let RECOVER_REWIND = 0.5 // seconds said again then: when exactly the engine stopped isn't known
let SETTLE = 0.45        // a new echo-cancelling engine resets itself within this; the speech waits for it
let MIC_STALL = 3.0      // listening, with no audio blocks for this long: the microphone is restarted
let MIC_HEAL_EVERY = 15.0 // (at most this often)

// MARK: - Recognizer

final class Recognizer {
  let analyzer: SpeechAnalyzer
  let transcriber: DictationTranscriber
  let format: AVAudioFormat
  let input: AsyncStream<AnalyzerInput>.Continuation

  init(analyzer: SpeechAnalyzer, transcriber: DictationTranscriber, format: AVAudioFormat,
       input: AsyncStream<AnalyzerInput>.Continuation) {
    self.analyzer = analyzer; self.transcriber = transcriber; self.format = format; self.input = input
  }

  // onResult(text, isFinal, startSeconds on the fed-audio timeline)
  static func make(onResult: @escaping (String, Bool, Double) -> Void) async throws -> Recognizer {
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
      fail("Apple's dictation doesn't support English on this Mac.")
    }
    let transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                                           reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await req.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      fail("No audio format for Apple's dictation.")
    }
    let context = AnalysisContext()
    context.contextualStrings[.general] = ["okay Buddy", "OK Buddy", "Buddy", "brain dump"]
    try await analyzer.setContext(context)
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: stream)
    Task {
      do {
        for try await r in transcriber.results {
          onResult(String(r.text.characters), r.isFinal, r.range.start.seconds)
        }
      } catch { emit("error", ["why": "dictation stopped: \(error.localizedDescription)", "fatal": true]); exit(1) }
    }
    return Recognizer(analyzer: analyzer, transcriber: transcriber, format: format, input: input)
  }
}

// MARK: - Utterances (pause detection on the audio timeline, so file mode is exact)

final class Utterances {
  var rec: Recognizer!
  var floor: Float = 0.005
  var loudRun = 0
  var quietFor = 0.0
  var speaking = false
  var spokeFor = 0.0
  var tail = 0
  var preroll: [AVAudioPCMBuffer] = []
  var fed = 0.0 // seconds of audio given to the recognizer so far
  var utt = 0
  // utterance -> where its audio starts and, once it's over, where the recognizer was told to finish it
  var parts: [Int: (start: Double, through: Double?, finals: [String], live: String)] = [:]
  var lastWords: [Int: String] = [:]
  var pendingEnds = 0
  var onIdle: (() -> Void)? = nil // file mode: called once every utterance has ended

  func peak(_ b: AVAudioPCMBuffer) -> Float {
    var p: Float = 0
    let n = Int(b.frameLength)
    if let ch = b.int16ChannelData {
      for i in 0..<n { p = max(p, abs(Float(ch[0][i]) / 32768)) }
    } else if let ch = b.floatChannelData {
      for i in 0..<n { p = max(p, abs(ch[0][i])) }
    }
    return p
  }

  // One BLOCK of audio in the recognizer's format.
  func block(_ b: AVAudioPCMBuffer) {
    let p = peak(b)
    let threshold = max(0.02, floor * 4)
    let loud = p > threshold
    let secs = Double(b.frameLength) / b.format.sampleRate
    if !speaking {
      if !loud { floor = min(0.05, floor * 0.98 + p * 0.02) }
      loudRun = loud ? loudRun + 1 : 0
      if tail > 0 { feed(b); tail -= 1 } else { preroll.append(b) } // the tail is fed already
      if preroll.count > PREROLL { preroll.removeFirst() }
      if loudRun >= 2 { begin() } // two loud blocks in a row: a click isn't speech
      return
    }
    feed(b)
    spokeFor += secs
    quietFor = loud ? 0 : quietFor + secs
    if quietFor >= gap { finish(split: false) }
    // a split is finalized in the middle of the dip: its end can hold the soft start of the next word
    else if spokeFor >= SOFT_UTTERANCE && quietFor >= SPLIT_QUIET { finish(split: true, back: quietFor / 2) }
    else if spokeFor >= MAX_UTTERANCE { finish(split: true) }
  }

  func feed(_ b: AVAudioPCMBuffer) {
    rec.input.yield(AnalyzerInput(buffer: b))
    fed += Double(b.frameLength) / b.format.sampleRate
  }

  func begin() {
    speaking = true; quietFor = 0; spokeFor = 0; loudRun = 0
    utt += 1
    parts[utt] = (start: fed, through: nil, finals: [], live: "")
    emit("start", ["utt": utt])
    for b in preroll { feed(b) }
    preroll.removeAll()
  }

  func finish(split: Bool, back: Double = 0) {
    speaking = false
    tail = TAIL
    let n = utt, through = fed - back
    parts[n]?.through = through
    pendingEnds += 1
    Task {
      try? await rec.analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 16000))
      work.asyncAfter(deadline: .now() + 0.05) {
        guard let part = self.parts[n] else { return }
        let text = (part.finals + [part.live]).joined(separator: " ").trimmed
        var fields: [String: Any] = ["utt": n, "text": text]
        if split { fields["split"] = true }
        emit("end", fields)
        self.parts[n] = nil; self.lastWords[n] = nil
        self.pendingEnds -= 1
        if self.pendingEnds == 0 && !self.speaking { self.onIdle?() }
      }
    }
  }

  // The microphone is going away: feed the tail the last finish waits for as silence.
  func quietTail() {
    let frames = AVAudioFrameCount(rec.format.sampleRate * BLOCK)
    for _ in 0..<(tail + 1) {
      guard let quiet = AVAudioPCMBuffer(pcmFormat: rec.format, frameCapacity: frames) else { return }
      quiet.frameLength = frames
      memset(quiet.audioBufferList.pointee.mBuffers.mData!, 0, Int(quiet.audioBufferList.pointee.mBuffers.mDataByteSize))
      feed(quiet)
    }
    tail = 0
  }

  // A result belongs to the first utterance the recognizer hadn't finished by its start.
  // (After a finish, the recognizer counts the quiet tail as the start of the next one.)
  func result(_ text: String, _ isFinal: Bool, _ start: Double) {
    let open = parts.keys.sorted().first { parts[$0]!.through.map { start < $0 - 0.02 } ?? true }
    guard let n = open ?? parts.keys.max(), var part = parts[n] else { return }
    if isFinal { part.finals.append(text.trimmed); part.live = "" } else { part.live = text.trimmed }
    parts[n] = part
    let words = (part.finals + [part.live]).joined(separator: " ").trimmed
    if !words.isEmpty && words != lastWords[n] {
      lastWords[n] = words
      emit("words", ["utt": n, "text": words])
    }
  }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

// Cuts converted audio into BLOCK-sized buffers, carrying the leftover.
final class Blocker {
  let format: AVAudioFormat
  let frames: AVAudioFrameCount
  var carry: AVAudioPCMBuffer
  init(format: AVAudioFormat) {
    self.format = format
    frames = AVAudioFrameCount(format.sampleRate * BLOCK)
    carry = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
  }
  func push(_ b: AVAudioPCMBuffer, _ each: (AVAudioPCMBuffer) -> Void) {
    let bytes = Int(format.streamDescription.pointee.mBytesPerFrame)
    var at = 0
    let n = Int(b.frameLength)
    while at < n {
      let take = min(Int(frames - carry.frameLength), n - at)
      let dst = carry.audioBufferList.pointee.mBuffers.mData!.advanced(by: Int(carry.frameLength) * bytes)
      let src = b.audioBufferList.pointee.mBuffers.mData!.advanced(by: at * bytes)
      memcpy(dst, src, take * bytes)
      carry.frameLength += AVAudioFrameCount(take)
      at += take
      if carry.frameLength == frames {
        each(carry)
        carry = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      }
    }
  }
}

func convert(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter, to want: AVAudioFormat) -> AVAudioPCMBuffer? {
  let cap = AVAudioFrameCount(Double(buf.frameLength) * want.sampleRate / buf.format.sampleRate + 64)
  guard let o = AVAudioPCMBuffer(pcmFormat: want, frameCapacity: cap) else { return nil }
  var given = false
  var err: NSError?
  conv.convert(to: o, error: &err) { _, status in
    if given { status.pointee = .noDataNow; return nil }
    given = true; status.pointee = .haveData; return buf
  }
  return o.frameLength > 0 ? o : nil
}

func converter(from: AVAudioFormat, to: AVAudioFormat) -> AVAudioConverter? {
  guard let c = AVAudioConverter(from: from, to: to) else { return nil }
  if from.channelCount > 1 { c.channelMap = [0] } // voice processing: channel 0 is the cleaned mic
  return c
}

// MARK: - The audio engine: mic in, speech out

final class Ear {
  let u: Utterances
  var engine = AVAudioEngine()
  var player = AVAudioPlayerNode()
  var listening = true
  struct Playing { let id: Int; var gen: Int; let file: AVAudioFile; var from: AVAudioFramePosition; var began: Date; var tries: Int }
  var playing: Playing? = nil
  var builtAt = Date(), lastBlock = Date(), lastHeal = Date.distantPast
  var engineVP = false                    // the running engine has voice processing on
  var engineFormat: AVAudioFormat? = nil  // and its player is connected for this format
  var gen = 0
  var settling: Int?                      // the speech (its gen) waiting for a new engine to settle
  var blocker: Blocker
  var calmTimer: DispatchWorkItem? = nil
  var observer: NSObjectProtocol? = nil
  var tapped = false // the mic tap is installed on this engine

  init(u: Utterances) { self.u = u; blocker = Blocker(format: u.rec.format) }

  // Rebuild the engine. Voice processing is on only while speech plays and we listen;
  // without listening the mic isn't touched at all (no orange dot). With no usable mic it
  // still speaks: only the listening part is left out.
  func build(vp: Bool, playFormat: AVAudioFormat?) {
    if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    engine.stop()
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    engine = AVAudioEngine()
    player = AVAudioPlayerNode()
    _ = engine.outputNode; _ = engine.mainMixerNode // voice processing won't start otherwise (-10875)
    // touching inputNode without an input device can raise an exception Swift can't catch
    let mic = listening && hasMic()
    if listening && !mic { emit("error", ["why": "no usable microphone", "fatal": false]) }
    if mic {
      let input = engine.inputNode
      if vp {
        do {
          try input.setVoiceProcessingEnabled(true)
          input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        } catch { emit("error", ["why": "echo cancellation: \(error.localizedDescription)", "fatal": false]) }
      }
      tap(input)
    }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                      queue: nil) { [weak self] _ in
      // a mic was plugged in or out, or the default device changed; in a speech the engine
      // may have stopped under the player
      work.async { self?.rebuild() }
    }
    builtAt = Date()
    engineVP = vp && tapped
    engineFormat = playFormat
    if !listening && playFormat == nil { return } // nothing to do: leave the engine off
    engine.prepare()
    do { try engine.start() } catch { emit("error", ["why": "audio engine: \(error.localizedDescription)", "fatal": false]) }
  }

  // The mic tap, in whatever format the input has now.
  func tap(_ input: AVAudioInputNode) {
    let fmt = input.outputFormat(forBus: 0)
    if fmt.sampleRate > 0, let conv = converter(from: fmt, to: u.rec.format) {
      let want = u.rec.format
      input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
        guard let self, let c = convert(buf, conv, to: want) else { return }
        // (in a speech the tap stays while listening is off: those blocks go nowhere)
        work.async { self.lastBlock = Date(); if self.listening { self.blocker.push(c) { self.u.block($0) } } }
      }
      tapped = true
    } else {
      emit("error", ["why": "no usable microphone", "fatal": false])
    }
  }

  // After a configuration change the engine has stopped and dropped its connections: wire
  // the same engine up again and start it. (A new engine with voice processing would change
  // the configuration all over again.)
  func restart(playFormat: AVAudioFormat) -> Bool {
    player.stop()
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false; tap(engine.inputNode) }
    engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    builtAt = Date()
    engine.prepare()
    return (try? engine.start()) != nil && engine.isRunning
  }

  func rebuild() {
    if playing != nil && settling != nil { settled(); return }
    if playing == nil { build(vp: false, playFormat: nil) } else if !engine.isRunning { recover() }
  }

  func listen(_ on: Bool) {
    guard on != listening else { return }
    // what was being said ends here: it isn't joined to what's said when listening comes back
    if !on && u.speaking { u.finish(split: false); u.quietTail() }
    if playing == nil { engine.stop(); if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false } }
    listening = on
    if playing == nil { build(vp: false, playFormat: nil) }
  }

  func speak(id: Int, path: String) {
    if let p = playing { cut(p) }
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) } catch {
      emit("error", ["why": "can't play \(path): \(error.localizedDescription)", "fatal": false])
      emit("spoken", ["id": id, "cut": true]); return
    }
    calmTimer?.cancel()
    playing = Playing(id: id, gen: 0, file: file, from: 0, began: Date(), tries: 0)
    if start() {
      emit("speaking", ["id": id, "secs": Double(file.length) / file.processingFormat.sampleRate])
    }
  }

  // Build the engine and play the speech from where it got to (playing.from). False: there's
  // no audio device, and the speech is over.
  func start(again: Bool = false) -> Bool {
    guard var p = playing else { return false }
    gen += 1
    p.gen = gen
    playing = p
    let format = p.file.processingFormat
    if again && restart(playFormat: format) {
    } else if !again && engine.isRunning && engineFormat == format && engineVP == (listening && tapped) {
      // the engine from the speech before is still up (the next piece of a long answer, the
      // next line in the queue): play on it. Every new engine is a round trip to macOS's audio
      // server, which can take seconds and now and then much longer.
      player.stop()
    } else {
      build(vp: listening, playFormat: format)
      if engineVP && engine.isRunning {
        // macOS resets an engine a moment (0.1 to 0.3 s) after echo cancellation comes on.
        // Played straight away, the first syllable would be cut off and said again: wait for
        // the reset (rebuild() plays then), or for long enough that none is coming.
        let g = p.gen
        settling = g
        work.asyncAfter(deadline: .now() + SETTLE) {
          guard self.settling == g else { return }
          self.settled()
        }
        return true
      }
    }
    return play()
  }

  // The new engine has had its reset, or isn't getting one: play.
  func settled() {
    settling = nil
    guard let p = playing else { return }
    if !engine.isRunning && !restart(playFormat: p.file.processingFormat) {
      build(vp: listening, playFormat: p.file.processingFormat)
    }
    _ = play()
  }

  func play() -> Bool {
    guard var p = playing else { return false }
    guard engine.isRunning else { // no audio device: say so instead of crashing in play()
      end(cut: true)
      return false
    }
    let g = p.gen
    let left = max(0, p.file.length - p.from)
    p.began = Date()
    playing = p
    player.scheduleSegment(p.file, startingFrame: p.from, frameCount: AVAudioFrameCount(left), at: nil,
                           completionCallbackType: .dataPlayedBack) { _ in
      work.async { self.played(g) }
    }
    player.play()
    // the engine always says when the audio has played, but if it ever doesn't, the speech
    // would never end
    let secs = Double(left) / p.file.processingFormat.sampleRate
    work.asyncAfter(deadline: .now() + secs + 1.5) {
      guard let now = self.playing, now.gen == g else { return }
      if self.engine.isRunning { self.end(cut: false) } else { self.recover() }
    }
    return true
  }

  // The player says the audio has played. It says so too when the engine was reset under it
  // (macOS changed the audio setup), with most of the speech unheard: then it's played again
  // from where it stopped.
  func played(_ g: Int) {
    guard let p = playing, p.gen == g else { return }
    let length = Double(p.file.length - p.from) / p.file.processingFormat.sampleRate
    if Date().timeIntervalSince(p.began) < length - 0.3 { recover() } else { end(cut: false) }
  }

  // The engine stopped in the middle of a speech (a configuration change: a device came or
  // went, or voice processing switched the devices over). Left alone nothing plays, nothing
  // is heard and the speech never ends, so start again from just before where it got to.
  func recover() {
    guard var p = playing else { return }
    let rate = p.file.processingFormat.sampleRate
    let into = Date().timeIntervalSince(p.began)
    let heard = max(0, into - RECOVER_REWIND)
    p.from = min(p.file.length, p.from + AVAudioFramePosition(heard * rate))
    p.tries += 1
    playing = p
    if p.tries > RECOVER_TRIES { end(cut: true); return }
    if Double(p.file.length - p.from) < 0.1 * rate { end(cut: false); return }
    emit("note", ["what": "audio restarted in a speech", "id": p.id, "try": p.tries, "after": into])
    _ = start(again: p.tries <= 2) // the same engine first, then a new one
  }

  // The speech is over: say so once, and let voice processing go.
  func end(cut: Bool) {
    guard let p = playing else { return }
    playing = nil
    settling = nil
    player.stop()
    emit("spoken", ["id": p.id, "cut": cut])
    calm()
  }

  func cut(_ p: Playing) {
    playing = nil
    settling = nil
    player.stop()
    emit("spoken", ["id": p.id, "cut": true])
  }

  func stop() { if let p = playing { cut(p); calm() } }

  // Twice a second: an engine that stopped in a speech is started again, and so is a
  // microphone that has gone quiet (no audio blocks at all for a few seconds).
  func check() {
    if playing != nil {
      if !engine.isRunning && settling == nil { recover() }
      return
    }
    let now = Date()
    guard listening, tapped, now.timeIntervalSince(builtAt) > MIC_STALL, now.timeIntervalSince(lastBlock) > MIC_STALL,
          now.timeIntervalSince(lastHeal) > MIC_HEAL_EVERY else { return }
    lastHeal = now
    emit("note", ["what": "microphone restarted", "running": engine.isRunning])
    build(vp: false, playFormat: nil)
  }

  // Voice processing off again a moment after the speech ends, unless he talks again.
  func calm() {
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.playing == nil else { return }
      self.build(vp: false, playFormat: nil)
    }
    calmTimer = item
    work.asyncAfter(deadline: .now() + CALM_AFTER, execute: item)
  }
}

// Is there a default input device at all? (A Mac mini or Mac Studio may have none.)
func hasMic() -> Bool {
  guard let dev = audioProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                            AudioObjectID(0)), dev != kAudioObjectUnknown else { return false }
  var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                        mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
}

// MARK: - Is another app using the mic? (a call or a meeting)

func audioProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
  var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var value = initial
  var size = UInt32(MemoryLayout<T>.size)
  return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

// Who else is recording from the mic: a dictation tool, a call, a recorder. Not only apps with
// a Dock icon: a menu-bar dictation app and a command-line tool (Claude Code's voice mode)
// count too. Left out: this helper and other copies of it (another assistant's ears), and
// macOS's own background listeners (Siri's), except its Dictation.
func micBusyApp() -> String? {
  let system = AudioObjectID(kAudioObjectSystemObject)
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
  let me = getpid()
  let mine = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? "buddy-ear"
  for id in ids {
    guard audioProp(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
          let pid = audioProp(id, kAudioProcessPropertyPID, pid_t(0)), pid != me else { continue }
    var buf = [CChar](repeating: 0, count: 4096)
    let path = proc_pidpath(pid, &buf, 4096) > 0 ? String(cString: buf) : ""
    if let name = micBusyName(path: path, mine: mine,
                              bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) { return name }
  }
  return nil
}

// The name to report for a process recording from the mic, or nil when it doesn't count.
func micBusyName(path: String, mine: String, bundle: String?) -> String? {
  let exe = (path as NSString).lastPathComponent
  if exe == mine || exe == "buddy-ear" { return nil }
  if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
    return path.contains("Dictation") ? "Dictation" : nil
  }
  return bundle ?? (exe.isEmpty ? "another app" : exe)
}

// MARK: - Main

let u = Utterances()
var ear: Ear? = nil

func runFile(_ path: String) {
  let file: AVAudioFile
  do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) } catch { fail("can't read \(path)") }
  guard let conv = converter(from: file.processingFormat, to: u.rec.format) else { fail("can't convert \(path)") }
  let blocker = Blocker(format: u.rec.format)
  let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
  var done = false
  u.onIdle = { if done { emit("eof"); exit(0) } }
  work.async {
    while let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
          (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 {
      if let c = convert(buf, conv, to: u.rec.format) { blocker.push(c) { u.block($0) } }
    }
    // the file ends in silence as far as we're concerned
    let quiet = AVAudioPCMBuffer(pcmFormat: u.rec.format, frameCapacity: blocker.frames)!
    quiet.frameLength = blocker.frames
    memset(quiet.audioBufferList.pointee.mBuffers.mData!, 0, Int(quiet.audioBufferList.pointee.mBuffers.mDataByteSize))
    var pad = 0.0
    while u.speaking && pad < gap + BLOCK { u.block(quiet); pad += BLOCK }
    for _ in 0..<(TAIL + 1) { u.block(quiet) }
    done = true
    if u.pendingEnds == 0 { emit("eof"); exit(0) }
  }
}

func readCommands() {
  Thread.detachNewThread {
    while let line = readLine() {
      guard let data = line.data(using: .utf8),
            let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
      work.async {
        guard let ear else { return }
        switch cmd["cmd"] as? String {
        case "listen": ear.listen(cmd["on"] as? Bool ?? true)
        case "speak":
          if let path = cmd["file"] as? String { ear.speak(id: cmd["id"] as? Int ?? 0, path: path) }
        case "stop": ear.stop()
        case "quit": exit(0)
        default: break
        }
      }
    }
    exit(0) // stdin closed: whoever started us is gone, so let go of the mic
  }
}

Task {
  do {
    u.rec = try await Recognizer.make { text, isFinal, start in work.async { u.result(text, isFinal, start) } }
  } catch { fail("dictation: \(error.localizedDescription)") }
  if let path = filePath { emit("ready"); runFile(path); return }
  work.sync {
    ear = Ear(u: u)
    ear!.listening = listenAtStart
    ear!.build(vp: false, playFormat: nil)
  }
  emit("ready")
  readCommands()
  var lastBusy: String? = nil
  let t = DispatchSource.makeTimerSource(queue: .main)
  t.schedule(deadline: .now() + 1, repeating: 0.5) // a live chat must notice another app taking the mic fast
  t.setEventHandler {
    work.async { ear?.check() }
    let busy = micBusyApp()
    if busy != lastBusy {
      if let busy { emit("busy", ["on": true, "app": busy]) } else { emit("busy", ["on": false]) }
      lastBusy = busy
    }
  }
  t.resume()
  busyTimer = t
}
var busyTimer: DispatchSourceTimer? = nil
RunLoop.main.run()
