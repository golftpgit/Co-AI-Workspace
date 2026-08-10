import Foundation

// ─────────────────────────────────────────────────────────────
// Builds `CONTENT { … }` blocks safely, in one place.
//
// Verified quirks of SurrealDB v3.2 this exists to handle
// (ARCHITECTURE App. C.0):
//
//  1. `NULL` is not `NONE`. A JSON null bound into an `option<string>` field
//     is rejected: "Expected `none | string` but found `NULL`". Optional
//     fields must be OMITTED, not sent as null.
//  2. A bound string shaped like `table:id` is interpreted as a record link,
//     so `"project:alpha"` fails a `TYPE string` field. Values that could
//     look like record ids must avoid the colon (see AgentKit.Scope).
//  3. `UPDATE` does not upsert: it errors when the record (or table) does
//     not exist yet. `UPSERT` is the create-or-replace statement.
// ─────────────────────────────────────────────────────────────

struct ContentBuilder {
    private var pairs: [String] = []
    private(set) var vars: [String: Any] = [:]

    /// Adds `field: $field` only when the value is present.
    mutating func set(_ field: String, _ value: Any?) {
        guard let value else { return }
        pairs.append("\(field): $\(field)")
        vars[field] = value
    }

    /// Adds a raw SurrealQL expression, e.g. `created_at: time::now()`.
    mutating func raw(_ field: String, _ expression: String) {
        pairs.append("\(field): \(expression)")
    }

    var content: String { "{ " + pairs.joined(separator: ", ") + " }" }

    /// Merges caller-supplied bindings (ids and so on) with the field vars.
    func vars(merging extra: [String: Any]) -> [String: Any] {
        vars.merging(extra) { _, new in new }
    }
}
