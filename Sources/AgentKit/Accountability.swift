import Foundation

// ─────────────────────────────────────────────────────────────
// Who is responsible, and who is accountable (ARCHITECTURE §19.5, §19.9, P10.5).
//
// Two rules from the standards are worth having in the type system rather than
// in a validator, because both are rules about what must be *impossible*:
//
//  1. **Exactly one accountable per work package.** Not "at most one, checked
//     later" — the field is a single non-optional value, so a package with two
//     accountable people cannot be written down, and neither can one with none.
//
//  2. **The Executive seat is never an agent's.** `BoardRole` has no case, no
//     initializer and no field that accepts a `Role`; the compiler refuses the
//     assignment rather than a rule refusing it at run time. That is the whole
//     of §19.5: the standards presuppose a human who answers for the business
//     case, and software cannot be that.
//
// The third rule — high-risk work is accountable to a person, not to the team
// lead — depends on how risky the deliverable is, which is a judgement rather
// than a shape, so it is checked where the gate can explain it.
// ─────────────────────────────────────────────────────────────

/// Anyone who can be *involved* in a work package.
public enum RACIActor: Sendable, Codable, Equatable, Hashable {
    case agent(Role)
    case human(String)

    public var label: String {
        switch self {
        case .agent(let role): role.rawValue
        case .human(let name): name.isEmpty ? "คน" : name
        }
    }

    public var isHuman: Bool {
        if case .human = self { return true }
        return false
    }
}

/// Anyone who can *answer for the result*. A deliberately smaller set than
/// `RACIActor`: a specialist does the work, but accountability sits with the
/// lead or with a person. There is no case here that takes an arbitrary role,
/// so `accountable: .agent(.engineer)` does not compile.
public enum Accountable: Sendable, Codable, Equatable, Hashable {
    case teamLead
    case human(String)

    public var label: String {
        switch self {
        case .teamLead: "หัวหน้าทีม"
        case .human(let name): name.isEmpty ? "คน" : name
        }
    }

    public var isHuman: Bool {
        if case .human = self { return true }
        return false
    }

    public var asActor: RACIActor {
        switch self {
        case .teamLead: .agent(.teamLead)
        case .human(let name): .human(name)
        }
    }
}

public struct RACI: Sendable, Codable, Equatable {
    /// One, always. The standard rule, expressed as a field rather than a
    /// validation: two accountable people is not a state this type has.
    public var accountable: Accountable
    /// At least one is expected, and the gate says so — but an empty list is a
    /// representable state on purpose, because a package can be accountable to
    /// someone before anyone has been given the work.
    public var responsible: [RACIActor]
    public var consulted: [RACIActor]
    public var informed: [RACIActor]

    public init(accountable: Accountable,
                responsible: [RACIActor] = [],
                consulted: [RACIActor] = [],
                informed: [RACIActor] = []) {
        self.accountable = accountable
        self.responsible = responsible
        self.consulted = consulted
        self.informed = informed
    }

    public var isStaffed: Bool { !responsible.isEmpty }
}

/// A seat on the project board (§19.5). PRINCE2's Executive and Senior User,
/// and nothing else in this file mentions `Role` — which is the point.
public struct BoardRole: Sendable, Codable, Equatable, Identifiable {
    public enum Seat: String, Sendable, Codable, CaseIterable {
        case executive
        case seniorUser

        public var label: String {
            switch self {
            case .executive: "ผู้รับผิดชอบทางธุรกิจ (Executive)"
            case .seniorUser: "ตัวแทนผู้ใช้ (Senior User)"
            }
        }
    }

    public let seat: Seat
    /// A person's name. There is no other way to fill this seat: no case takes
    /// a `Role`, and no initializer accepts one.
    public let person: String

    public var id: String { seat.rawValue }

    public init(seat: Seat, person: String) {
        self.seat = seat
        self.person = person
    }

    public var isFilled: Bool {
        !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
