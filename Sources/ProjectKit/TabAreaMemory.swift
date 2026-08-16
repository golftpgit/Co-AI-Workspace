import Foundation

// ─────────────────────────────────────────────────────────────
// Where each open tab was, so switching back lands where you left (§19.1.1,
// P21.1).
//
// Measured on the real app before this existed as a type: set tab A to the
// Workbench, General to Knowledge and tab B to System, then read all three
// back — **all three said System**, the area of whichever tab was touched last
// (E.34). Nothing was remembered per tab at all.
//
// The arrangement it replaces was two SwiftUI observers over the same two
// pieces of state:
//
//     .onChange(of: area)   { _, now in remembered[active.id] = now }
//     .onChange(of: active) { _, now in area = remembered[now.id] ?? .chat }
//
// Both handlers threw away the `previous` value they were handed and read
// `active` for the id to file under. During a switch that id has already moved,
// so the tab being *left* was filed under the name of the tab being *arrived
// at* — and because restoring writes the same `area` the recorder watches, a
// restore is indistinguishable from a person choosing, so the two fire in an
// order nothing guarantees.
//
// The fix is not a smarter observer, it is removing the second one. A switch is
// a single event with two ends, and both ends are known at the moment it
// happens: **which tab is being left, showing what, and which tab is being
// arrived at.** Given those three, nothing has to be inferred from state that
// is mid-move.
// ─────────────────────────────────────────────────────────────

/// What to show on arriving at a tab.
public enum TabArrival<Area: Sendable & Equatable>: Sendable, Equatable {
    /// This tab has been here before; put it back where it was.
    case restore(Area)
    /// Never opened, or opened and closed since. The caller decides what a
    /// fresh tab starts on — deliberately not a default stored here, because
    /// "where a new workspace opens" is a product decision that already lives
    /// next to the panel emphasis it goes with (§24.3).
    case fresh
}

/// Keyed by tab **id**, not by tab: a project that is closed and reopened is a
/// fresh window onto it, not a resumption of where somebody was before they
/// closed it.
public struct TabAreaMemory<Area: Sendable & Equatable & Hashable>: Sendable, Equatable {
    private var remembered: [String: Area] = [:]

    public init() {}

    /// One switch, both ends given.
    ///
    /// - Parameters:
    ///   - leaving: the id of the tab being left. Passed in rather than read,
    ///     because by the time anything notices a switch this is no longer the
    ///     current tab — which is the whole of the bug this replaces.
    ///   - showing: what that tab was on. Banked here, so nothing needs to
    ///     watch for every change in between.
    ///   - arriving: the id of the tab being moved to.
    public mutating func moved(leaving: String, showing: Area,
                               arriving: String) -> TabArrival<Area> {
        remembered[leaving] = showing
        // A tab switched to itself is not a switch; returning `.fresh` for it
        // would reset the area of the tab somebody is already looking at.
        guard leaving != arriving else { return .restore(showing) }
        return remembered[arriving].map(TabArrival.restore) ?? .fresh
    }

    /// Forgets a closed tab, so reopening it starts fresh.
    public mutating func closed(_ id: String) {
        remembered.removeValue(forKey: id)
    }

    /// For tests and for the status line — never used to decide anything.
    public func recorded(for id: String) -> Area? { remembered[id] }
}
