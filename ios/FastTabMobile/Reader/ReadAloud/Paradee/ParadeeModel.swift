import Foundation
import OnnxRuntimeBindings

enum ParadeeError: Error, Equatable {
    /// The model or its config isn't in the app bundle / doesn't load.
    case modelUnavailable(String)
    /// No English text-to-phoneme converter in this build.
    case phonemizerUnavailable
    /// This model doesn't have the voice.
    case unknownVoice(String)
    case inferenceFailed(String)
}

/// Padded token ids → 24 kHz float waveform. A protocol so the renderer is testable
/// without ONNX Runtime.
protocol ParadeeWaveformModel: Sendable {
    func waveform(ids: [Int64], voiceIndex: Int64, speed: Float) throws -> [Float]
}

/// `paradee_int8.onnx` in ONNX Runtime. Inputs: `input_ids` int64 [1, T], `speed` float32 [1],
/// `voice` int64 [1]; output `waveform` float32 [1, samples]. The graph draws its own noise.
final class ParadeeONNXModel: ParadeeWaveformModel, @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    /// One inference at a time: Read Aloud only ever needs one, and it keeps memory flat.
    private let lock = ParadeeInferenceLock()

    init(modelPath: String) throws {
        do {
            env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            // One thread is ~60x real time on a Mac; leaves the other cores to the UI.
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        } catch {
            throw ParadeeError.modelUnavailable(error.localizedDescription)
        }
    }

    func waveform(ids: [Int64], voiceIndex: Int64, speed: Float) throws -> [Float] {
        try lock.run { try infer(ids: ids, voiceIndex: voiceIndex, speed: speed) }
    }

    private func infer(ids: [Int64], voiceIndex: Int64, speed: Float) throws -> [Float] {
        do {
            let inputs: [String: ORTValue] = [
                "input_ids": try Self.tensor(ids, .int64, shape: [1, ids.count]),
                "speed": try Self.tensor([speed], .float, shape: [1]),
                "voice": try Self.tensor([voiceIndex], .int64, shape: [1]),
            ]
            let outputs = try session.run(withInputs: inputs, outputNames: ["waveform"], runOptions: nil)
            guard let waveform = outputs["waveform"] else { throw ParadeeError.inferenceFailed("no waveform output") }
            let data = try waveform.tensorData() as Data
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch let error as ParadeeError {
            throw error
        } catch {
            throw ParadeeError.inferenceFailed(error.localizedDescription)
        }
    }

    private static func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<T>.stride) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }
}

/// Serializes model inferences. Rapid ±15 s skips cancel sentence renders that are still
/// queued here behind the running inference; each one checks cancellation once it holds the
/// lock and bails with `CancellationError`, so only the current sentence's work runs (an
/// inference already running can't be interrupted, but it is at most one ≤510-id piece).
final class ParadeeInferenceLock: @unchecked Sendable {
    private let lock = NSLock()

    func run<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        return try body()
    }
}

/// One sentence of Paradee audio plus what it cost to make (trial instrumentation).
struct ParadeeRenderedSentence: Sendable {
    let samples: [Float]
    let sampleRate: Int
    /// Token ids the model read (without pads), and in how many model calls.
    let idCount: Int
    let pieces: Int
    /// Phonemizing + inference, wall clock.
    let synthesisSeconds: Double

    var audioSeconds: Double { Double(samples.count) / Double(sampleRate) }
    /// Synthesis time / audio time: below 1 is faster than real time.
    var realTimeFactor: Double { audioSeconds > 0 ? synthesisSeconds / audioSeconds : 0 }
}

/// Sentence text → audio. Runs off the main thread.
protocol ParadeeRendering: Sendable {
    func render(_ text: String, voice: ParadeeVoice, speed: Float) throws -> ParadeeRenderedSentence
}

/// G2P → ids → (pieces of ≤510 ids, each padded) → model, pieces' audio joined.
/// A cancelled render (the run was stopped or skipped) throws `CancellationError` before its
/// next piece instead of finishing the sentence.
struct ParadeeRenderer: ParadeeRendering {
    let phonemizer: ParadeePhonemizing
    let tokenizer: ParadeeTokenizer
    let model: ParadeeWaveformModel
    let config: ParadeeConfig

    func render(_ text: String, voice: ParadeeVoice, speed: Float) throws -> ParadeeRenderedSentence {
        guard let voiceIndex = config.index(of: voice) else { throw ParadeeError.unknownVoice(voice.rawValue) }
        let started = Date()
        let ids = tokenizer.ids(for: phonemizer.phonemes(for: text, accent: voice.accent))
        let pieces = tokenizer.pieces(of: ids)
        var samples: [Float] = []
        for piece in pieces {
            try Task.checkCancellation()
            samples += try model.waveform(ids: ParadeeTokenizer.padded(piece), voiceIndex: voiceIndex, speed: speed)
        }
        // NaN would trap in `ParadeeWAV.encode` (Int16(NaN)); fail instead → device voice fallback.
        guard samples.allSatisfy(\.isFinite) else { throw ParadeeError.inferenceFailed("non-finite audio") }
        return ParadeeRenderedSentence(samples: samples, sampleRate: config.sampleRate, idCount: ids.count,
                                       pieces: pieces.count, synthesisSeconds: Date().timeIntervalSince(started))
    }
}

/// Loads the bundled model once per app run (kept for later articles: ~8.5 MB of weights).
/// Thread-safe; call it off the main thread, the first load takes a moment.
final class ParadeeRuntime: @unchecked Sendable {
    static let shared = ParadeeRuntime()

    static let modelResource = "paradee_int8"
    static let configResource = "paradee_config"

    private let lock = NSLock()
    private var loaded: ParadeeRenderer?

    /// The English text → phoneme converter shipped in this app (misaki port, `G2P/` + `G2PData/`).
    static func makePhonemizer(bundle: Bundle) -> ParadeePhonemizing? {
        ParadeeG2P(bundle: bundle)
    }

    func renderer(bundle: Bundle = .main) throws -> ParadeeRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let started = Date()
        guard let phonemizer = Self.makePhonemizer(bundle: bundle) else { throw ParadeeError.phonemizerUnavailable }
        let renderer = try Self.load(bundle: bundle, phonemizer: phonemizer)
        let seconds = Date().timeIntervalSince(started)
        readAloudLog.info("paradee model loaded in \(String(format: "%.2f", seconds), privacy: .public)s")
        loaded = renderer
        return renderer
    }

    static func load(bundle: Bundle, phonemizer: ParadeePhonemizing) throws -> ParadeeRenderer {
        guard let modelPath = bundle.path(forResource: modelResource, ofType: "onnx"),
              let configURL = bundle.url(forResource: configResource, withExtension: "json") else {
            throw ParadeeError.modelUnavailable("not in bundle")
        }
        let config: ParadeeConfig
        do {
            config = try JSONDecoder().decode(ParadeeConfig.self, from: Data(contentsOf: configURL))
        } catch {
            throw ParadeeError.modelUnavailable("config: \(error.localizedDescription)")
        }
        return ParadeeRenderer(phonemizer: phonemizer, tokenizer: ParadeeTokenizer(vocab: config.vocab),
                               model: try ParadeeONNXModel(modelPath: modelPath), config: config)
    }
}
