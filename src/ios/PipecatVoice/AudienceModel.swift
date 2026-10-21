import CoreML
import Foundation

/// Pipecat Audience on Core ML: how likely a line is to be for each person present, whether it is unclear who it
/// is for, and whether it is for the whole group. The Python side renders the request with Audience's reference
/// runtime (each card's text, the line's text, the features); this tokenizes and runs the encoder and the head as
/// the runtime's cached-cards classifier does on ONNX Runtime. Each card is encoded once and kept by its text.
/// Not thread-safe: the owner calls it from one queue.
final class AudienceModel: @unchecked Sendable {
    struct Answer: Equatable, Sendable {
        let person: [Double]
        let unclear: Double
        let group: Double
    }

    private struct States {
        let h: [Float]  // tokens × hidden
        let hp: [Float]  // tokens × projected
        let count: Int
    }

    private let encoder: MLModel
    private let headURL: URL
    private let configuration: MLModelConfiguration
    private var heads: [Int: MLModel] = [:]
    private let tokenizer: AudienceTokenizer
    private let cardLength: Int
    private let lineLength: Int
    private let tokens: Int
    private let lineTokens: Int
    private let padID: Int32
    private let hidden: Int
    private let projected: Int
    private let temperatures: (person: Double, unclear: Double, group: Double)
    private var cards: [String: States] = [:]
    static let maximumPeople = 8

    /// Load the models from a folder holding `AudienceEncoder.mlmodelc`, `AudienceHead.mlmodelc`, `tokenizer.json`,
    /// `config.json` and `coreml.json`.
    init(directory: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        func json(_ name: String) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name)))
                    as? [String: Any] else { throw VoiceError(message: "Audience's \(name) is not a JSON object.") }
            return object
        }
        let config = try json("config.json")
        let coreml = try json("coreml.json")
        guard config["render_version"] as? String == "addressee-tt-0.6",
              let cardLength = config["card_len"] as? Int, let lineLength = config["line_len"] as? Int,
              let temperatures = config["temperatures"] as? [String: Double],
              let person = temperatures["person"], let unclear = temperatures["unclear"], let group = temperatures["group"],
              let encoder = coreml["encoder"] as? [String: Any], let tokens = encoder["tokens"] as? Int,
              let padID = encoder["pad_id"] as? Int, let head = coreml["head"] as? [String: Any],
              let lineTokens = head["line_tokens"] as? Int, cardLength <= tokens, lineLength <= min(tokens, lineTokens) else {
            throw VoiceError(message: "Audience's model files are not the addressee-tt-0.6 Core ML conversion.")
        }
        self.cardLength = cardLength
        self.lineLength = lineLength
        self.tokens = tokens
        self.lineTokens = lineTokens
        self.padID = Int32(padID)
        self.temperatures = (person, unclear, group)
        configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.encoder = try MLModel(contentsOf: directory.appendingPathComponent("AudienceEncoder.mlmodelc"),
                                   configuration: configuration)
        headURL = directory.appendingPathComponent("AudienceHead.mlmodelc")
        tokenizer = try AudienceTokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let outputs = self.encoder.modelDescription.outputDescriptionsByName
        guard let h = outputs["h"]?.multiArrayConstraint?.shape.last?.intValue,
              let hp = outputs["hp"]?.multiArrayConstraint?.shape.last?.intValue else {
            throw VoiceError(message: "Audience's encoder lacks its h and hp outputs.")
        }
        hidden = h
        projected = hp
    }

    /// Score a line. `cards` are the people's card texts in request order, `line` the line input with the line
    /// before it, `current` the current line's length in characters, `people` and `features` the runtime's
    /// person and line features.
    func answer(cards: [String], line: String, current: Int, people: [[Float]], features: [Float]) throws -> Answer {
        let count = cards.count
        guard (1...Self.maximumPeople).contains(count), people.count == count else {
            throw VoiceError(message: "Audience reads one to \(Self.maximumPeople) people with features for each.")
        }
        let encoded = try cards.map(card)
        let lineEncoding = tokenizer.encode(line, maxLength: lineLength)
        let (lineStates, pooled) = try encode(lineEncoding.ids)

        let q = try array([1, hidden], pooled)
        var h = [Float](repeating: 0, count: lineTokens * hidden)
        var hp = [Float](repeating: 0, count: lineTokens * projected)
        h.replaceSubrange(0..<lineStates.h.count, with: lineStates.h)
        hp.replaceSubrange(0..<lineStates.hp.count, with: lineStates.hp)
        var cur = [Float](repeating: 0, count: lineTokens)
        for (i, span) in lineEncoding.offsets.enumerated() where span.end > span.start && span.end <= current {
            cur[i] = 1
        }
        var g = [Float](repeating: 0, count: count * tokens * hidden)
        var gp = [Float](repeating: 0, count: count * tokens * projected)
        var mask = [Int32](repeating: 0, count: count * tokens)
        for (person, states) in encoded.enumerated() {
            g.replaceSubrange(person * tokens * hidden..<(person * tokens * hidden + states.h.count), with: states.h)
            gp.replaceSubrange(person * tokens * projected..<(person * tokens * projected + states.hp.count), with: states.hp)
            for t in 0..<states.count { mask[person * tokens + t] = 1 }
        }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "q": q,
            "h": try array([1, lineTokens, hidden], h),
            "hp": try array([1, lineTokens, projected], hp),
            "cur": try array([1, lineTokens], cur),
            "g": try array([count, tokens, hidden], g),
            "gp": try array([count, tokens, projected], gp),
            "card_mask": try array([count, tokens], mask),
            "pfeat": try array([count, people[0].count], people.flatMap { $0 }),
            "lfeat": try array([1, features.count], features),
        ])
        let out = try head(count).prediction(from: inputs)
        func values(_ name: String) throws -> [Float] {
            guard let value = out.featureValue(for: name)?.multiArrayValue else {
                throw VoiceError(message: "Audience's head returned no \(name).")
            }
            return Self.floats(value)
        }
        let personLogits = try values("person")
        guard personLogits.count == count, let unclear = try values("unclear").first,
              let group = try values("group").first else {
            throw VoiceError(message: "Audience's head returned scores of the wrong shape.")
        }
        return Answer(person: personLogits.map { Self.sigmoid(Double($0) / temperatures.person) },
                      unclear: Self.sigmoid(Double(unclear) / temperatures.unclear),
                      group: Self.sigmoid(Double(group) / temperatures.group))
    }

    private func card(_ text: String) throws -> States {
        if let hit = cards[text] { return hit }
        let (states, _) = try encode(tokenizer.encode(text, maxLength: cardLength).ids)
        cards[text] = states
        return states
    }

    /// The real tokens' states and the pooled vector, from inputs padded to the encoder's fixed length.
    private func encode(_ ids: [Int32]) throws -> (States, [Float]) {
        var padded = [Int32](repeating: padID, count: tokens)
        var mask = [Int32](repeating: 0, count: tokens)
        padded.replaceSubrange(0..<ids.count, with: ids)
        for i in ids.indices { mask[i] = 1 }
        let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "ids": try array([1, tokens], padded), "mask": try array([1, tokens], mask),
        ]))
        guard let h = out.featureValue(for: "h")?.multiArrayValue, let hp = out.featureValue(for: "hp")?.multiArrayValue,
              let pooled = out.featureValue(for: "pooled")?.multiArrayValue else {
            throw VoiceError(message: "Audience's encoder returned no states.")
        }
        let n = ids.count
        let states = States(h: Self.floats(h, first: n * hidden), hp: Self.floats(hp, first: n * projected), count: n)
        return (states, Self.floats(pooled))
    }

    /// The head function for this many people, loaded on first use.
    private func head(_ people: Int) throws -> MLModel {
        if let model = heads[people] { return model }
        let configuration = self.configuration.copy() as! MLModelConfiguration
        configuration.functionName = "people_\(people)"
        let model = try MLModel(contentsOf: headURL, configuration: configuration)
        heads[people] = model
        return model
    }

    private func array<Scalar>(_ shape: [Int], _ values: [Scalar]) throws -> MLMultiArray {
        guard shape.reduce(1, *) == values.count else {
            throw VoiceError(message: "Audience was given \(values.count) values for shape \(shape).")
        }
        precondition(Scalar.self == Float.self || Scalar.self == Int32.self, "Audience inputs are Float or Int32")
        let type: MLMultiArrayDataType = Scalar.self == Int32.self ? .int32 : .float32
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        // A new array is contiguous in row-major order.
        array.withUnsafeMutableBytes { bytes, _ in
            values.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        return array
    }

    /// The leading `first` values (all by default) of an output, in row-major order.
    private static func floats(_ array: MLMultiArray, first: Int? = nil) -> [Float] {
        let count = min(first ?? array.count, array.count)
        let shape = array.shape.map(\.intValue)
        var contiguous = array.dataType == .float32
        var stride = 1
        for (dimension, size) in zip(array.strides.map(\.intValue), shape).reversed() {
            contiguous = contiguous && (size == 1 || dimension == stride)
            stride *= size
        }
        guard contiguous else { return Array(MLShapedArray<Float>(converting: array).scalars.prefix(count)) }
        return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count)) }
    }

    private static func sigmoid(_ x: Double) -> Double {
        x >= 0 ? 1 / (1 + exp(-x)) : exp(x) / (1 + exp(x))
    }
}

/// Runs Audience off the main actor, one request at a time, with the bundled models loaded on
/// first use (or ahead of time with `prepare`). Models that fail to load are not retried until
/// `unload`: each request fails at once, and Python reads the line with Audience's rules
/// baseline instead.
final class AudienceRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice.audience", qos: .userInitiated)
    // Touched only on `queue`.
    private var model: Result<AudienceModel, Error>?

    func prepare() async throws {
        try await run { _ in }
    }

    /// Free the model; the next request loads it again.
    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                model = nil
                continuation.resume()
            }
        }
    }

    func answer(cards: [String], line: String, current: Int, people: [[Float]],
                features: [Float]) async throws -> AudienceModel.Answer {
        try await run { try $0.answer(cards: cards, line: line, current: current, people: people, features: features) }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (AudienceModel) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let model = self.model ?? Result {
                    guard let directory = Bundle.main.url(forResource: "audience", withExtension: nil) else {
                        throw VoiceError(message: "Pipecat Audience is missing from the app bundle.")
                    }
                    return try AudienceModel(directory: directory)
                }
                self.model = model
                continuation.resume(with: Result { try body(model.get()) })
            }
        }
    }
}
