import Foundation

// ─────────────────────────────────────────────────────────────
// Where the models above Tier 0.5 live (ARCHITECTURE §9.3, P5.5).
//
// One endpoint pair in bootstrap.plist was enough while there was exactly one
// server. It stops being enough the moment there are two — a workstation and a
// laptop, a free one and a metered one — because the two questions that matter
// are per-endpoint: *is it reachable*, and *does it cost money*.
//
// `kind` is the one that has teeth: a self-hosted endpoint is unmetered and
// goes straight through, a paid one may not be touched until the Budget
// Governor has agreed (§9.5). Nothing else in the system distinguishes them,
// so this flag is the whole boundary between "free" and "billable".
// ─────────────────────────────────────────────────────────────

public struct InferenceEndpoint: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// vLLM, LM Studio, Ollama — someone else's machine, no bill.
        case selfHosted
        /// A hosted API that charges per token. Never used without the
        /// governor's say-so.
        case paid
    }

    public let id: String
    public var name: String
    /// OpenAI-compatible base, including `/v1`.
    public var baseURL: String
    public var model: String
    public var kind: Kind
    /// Read from the environment rather than stored here: bootstrap.plist is a
    /// plain file in Application Support, and a key in it is a key on disk.
    /// Keychain proper is P9.2; naming the variable is what lets a paid
    /// endpoint work at all before then.
    public var apiKeyEnvironmentVariable: String?
    /// What a million tokens costs, so the governor can estimate before firing
    /// rather than count the damage afterwards. Nil for self-hosted.
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?

    public init(id: String = UUID().uuidString,
                name: String,
                baseURL: String,
                model: String,
                kind: Kind = .selfHosted,
                apiKeyEnvironmentVariable: String? = nil,
                inputPricePerMillion: Double? = nil,
                outputPricePerMillion: Double? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.kind = kind
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }

    public var url: URL? { URL(string: baseURL) }

    /// The key itself, from the environment. Absent is not an error here — the
    /// probe reports it, and a paid endpoint with no key simply never becomes
    /// available.
    public var apiKey: String? {
        apiKeyEnvironmentVariable.flatMap { ProcessInfo.processInfo.environment[$0] }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct EndpointRegistry: Codable, Sendable, Equatable {
    public var endpoints: [InferenceEndpoint]
    public var defaultEndpointID: String?
    /// Per-role overrides (§9.3). A role that is not listed uses the default.
    public var overrides: [String: String]

    public init(endpoints: [InferenceEndpoint] = [],
                defaultEndpointID: String? = nil,
                overrides: [String: String] = [:]) {
        self.endpoints = endpoints
        self.defaultEndpointID = defaultEndpointID
        self.overrides = overrides
    }

    public var isEmpty: Bool { endpoints.isEmpty }

    public func endpoint(id: String?) -> InferenceEndpoint? {
        guard let id else { return nil }
        return endpoints.first { $0.id == id }
    }

    /// The endpoint a role should use: its override, else the default, else
    /// the first one configured.
    public func endpoint(forRole role: String) -> InferenceEndpoint? {
        endpoint(id: overrides[role]) ?? endpoint(id: defaultEndpointID) ?? endpoints.first
    }

    public mutating func upsert(_ endpoint: InferenceEndpoint) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        if defaultEndpointID == nil { defaultEndpointID = endpoint.id }
    }

    public mutating func remove(id: String) {
        endpoints.removeAll { $0.id == id }
        overrides = overrides.filter { $0.value != id }
        if defaultEndpointID == id { defaultEndpointID = endpoints.first?.id }
    }
}

// MARK: - checking one before it is saved

public struct EndpointCheck: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case ok(models: Int)
        /// The server answered, but does not serve the model that was typed.
        /// This is the case that has to be caught here: an OpenAI-compatible
        /// server accepts a request for a model it does not have and fails
        /// much later, somewhere with no idea a name was misspelled
        /// (ARCHITECTURE E.9, case 8a).
        case unknownModel(available: [String])
        case unreachable(String)
        case missingKey(String)
    }

    public let verdict: Verdict
    public var isUsable: Bool { if case .ok = verdict { return true }; return false }

    public var message: String {
        switch verdict {
        case .ok(let count): "ต่อได้ · เสิร์ฟอยู่ \(count) โมเดล"
        case .unknownModel(let available):
            "ต่อได้ แต่ไม่มีโมเดลชื่อนี้ — ที่มีคือ "
                + (available.isEmpty ? "(ไม่มีเลย)" : available.prefix(4).joined(separator: ", "))
        case .unreachable(let detail): "ต่อไม่ได้: \(detail)"
        case .missingKey(let variable): "ยังไม่มีคีย์ — ตั้ง \(variable) ใน environment ก่อน"
        }
    }
}

public struct EndpointProbe: Sendable {
    public init() {}

    /// Asks the endpoint what it serves and checks the configured name against
    /// the answer. Run when saving, and again from "ตรวจใหม่ทั้งหมด".
    public func check(_ endpoint: InferenceEndpoint, timeout: TimeInterval = 4) async -> EndpointCheck {
        guard let url = endpoint.url else {
            return EndpointCheck(verdict: .unreachable("URL ใช้ไม่ได้: \(endpoint.baseURL)"))
        }
        if endpoint.kind == .paid, let variable = endpoint.apiKeyEnvironmentVariable,
           endpoint.apiKey == nil {
            return EndpointCheck(verdict: .missingKey(variable))
        }

        var request = URLRequest(url: url.appending(path: "models"))
        request.timeoutInterval = timeout
        if let key = endpoint.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return EndpointCheck(verdict: .unreachable("ไม่ได้รับ HTTP response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return EndpointCheck(verdict: .unreachable("HTTP \(http.statusCode)"))
            }
            let available = Self.modelNames(in: data)
            return available.contains(endpoint.model)
                ? EndpointCheck(verdict: .ok(models: available.count))
                : EndpointCheck(verdict: .unknownModel(available: available))
        } catch {
            return EndpointCheck(verdict: .unreachable((error as NSError).localizedDescription))
        }
    }

    static func modelNames(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}
