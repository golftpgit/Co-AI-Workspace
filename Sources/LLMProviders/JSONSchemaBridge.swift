import Foundation
import FoundationModels

// ─────────────────────────────────────────────────────────────
// Bridges our portable JSON Schema text onto Apple's runtime schema type.
//
// Apple's ergonomic path is `@Generable`, a compile-time macro — but tool
// arguments and agent output shapes are only known at runtime (from
// manifests and MCP servers), so `DynamicGenerationSchema` is the only way
// on-device generation can serve them.
// ─────────────────────────────────────────────────────────────

enum JSONSchemaBridge {
    enum BridgeError: Error, CustomStringConvertible {
        case notAnObject
        case unsupported(String)

        var description: String {
            switch self {
            case .notAnObject: return "root schema must be an object"
            case .unsupported(let t): return "unsupported JSON Schema construct: \(t)"
            }
        }
    }

    /// Converts a JSON Schema document into a `GenerationSchema`.
    /// Supports the subset the system actually emits: objects, strings
    /// (incl. `enum`), booleans, integers, numbers and arrays of those.
    static func generationSchema(name: String, json: String) throws -> GenerationSchema {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.notAnObject
        }
        let dynamic = try schema(named: name, from: root)
        return try GenerationSchema(root: dynamic, dependencies: [])
    }

    private static func schema(named name: String, from node: [String: Any]) throws -> DynamicGenerationSchema {
        let description = node["description"] as? String

        // `enum` wins over `type`: a constrained string is far more useful to
        // the model than a free one, and this is how role/severity fields work.
        if let choices = node["enum"] as? [String] {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }

        switch node["type"] as? String {
        case "object":
            let required = Set(node["required"] as? [String] ?? [])
            let properties = node["properties"] as? [String: Any] ?? [:]
            // Sorted so the generated schema is deterministic run to run.
            let fields = try properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
                guard let child = properties[key] as? [String: Any] else {
                    throw BridgeError.unsupported("property '\(key)'")
                }
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: child["description"] as? String,
                    schema: try schema(named: key, from: child),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: fields)

        case "array":
            guard let items = node["items"] as? [String: Any] else {
                throw BridgeError.unsupported("array without items")
            }
            return DynamicGenerationSchema(
                arrayOf: try schema(named: "\(name)Item", from: items),
                minimumElements: node["minItems"] as? Int,
                maximumElements: node["maxItems"] as? Int)

        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case let other:
            throw BridgeError.unsupported(other ?? "missing type")
        }
    }
}
