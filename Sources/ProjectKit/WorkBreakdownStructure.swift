import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The WBS as a value (ARCHITECTURE §19.6, P10.4).
//
// The packages are stored flat, with parent pointers, because that is what a
// database can index and what a plan being edited actually looks like. The tree
// is derived here, and so is every rule about whether the plan holds together.
//
// The rules are worth stating as rules rather than as advice, because each one
// describes a plan that looks complete and is not:
//
//  • a group with no leaves is a heading, not a deliverable;
//  • a leaf with no acceptance criteria is work nobody can review;
//  • a leaf that points at no in-scope line is work nobody agreed to;
//  • a package whose parent does not exist is a branch that fell off the tree.
//
// G2 reads all four. That is the whole point of having them: they fail a gate
// rather than appear in a report somebody skims.
// ─────────────────────────────────────────────────────────────

public struct WBSProblem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case emptyGroup
        case noAcceptanceCriteria
        case noScopeRef
        case danglingScopeRef
        case missingParent
        case cycle
        case noAccountable
        case highRiskWithoutHuman
        case missingDependency
        case dependencyCycle
    }

    public let kind: Kind
    public let packageID: String
    public let title: String

    public var id: String { "\(kind.rawValue):\(packageID)" }

    public var text: String {
        switch kind {
        case .emptyGroup: t("“\(title)” has nothing inside it — that is a heading, not something deliverable",
                            "Refusal message. Placeholder is the package title.")
        case .noAcceptanceCriteria: t("“\(title)” does not say what done means",
                                      "Refusal message. Placeholder is the package title.")
        case .noScopeRef: t("“\(title)” is not tied to anything in scope",
                            "Refusal message. Placeholder is the package title.")
        case .danglingScopeRef: t("“\(title)” is tied to a scope line that no longer exists",
                                  "Refusal message. Placeholder is the package title.")
        case .missingParent: t("“\(title)” names a parent that does not exist",
                               "Refusal message. Placeholder is the package title.")
        case .cycle: t("“\(title)” loops back to itself",
                       "Refusal message. Placeholder is the package title.")
        case .noAccountable: t("“\(title)” has nobody accountable (A)",
                               "Refusal message. Placeholder is the package title. A is the RACI letter.")
        case .highRiskWithoutHuman:
            t("“\(title)” is classed high risk — the accountable (A) has to be a person, not the team lead",
              "Refusal message. Placeholder is the package title.")
        case .missingDependency: t("“\(title)” waits on a package that no longer exists",
                                   "Refusal message. Placeholder is the package title.")
        case .dependencyCycle: t("“\(title)” is in a cycle of packages waiting on each other — none of them can start",
                                 "Refusal message. Placeholder is the package title.")
        }
    }
}

public struct WorkBreakdown: Sendable, Equatable {
    public let packages: [WorkPackage]

    public init(_ packages: [WorkPackage] = []) {
        self.packages = packages
    }

    private var byID: [String: WorkPackage] {
        Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var isEmpty: Bool { packages.isEmpty }

    public func children(of parent: String?) -> [WorkPackage] {
        packages.filter { $0.parent == parent }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    public var roots: [WorkPackage] { children(of: nil) }

    /// A package with no children. The unit of work, and the only kind that
    /// becomes an `Assignment`.
    public func isLeaf(_ package: WorkPackage) -> Bool {
        !packages.contains { $0.parent == package.id }
    }

    public var leaves: [WorkPackage] { packages.filter(isLeaf) }

    public var openLeaves: [WorkPackage] { leaves.filter { $0.status.isOpen } }

    /// Depth-first, in plan order — what the screen draws and what a report
    /// lists.
    public var ordered: [WorkPackage] {
        var result: [WorkPackage] = []
        var seen = Set<String>()
        func walk(_ parent: String?) {
            for package in children(of: parent) where !seen.contains(package.id) {
                seen.insert(package.id)
                result.append(package)
                walk(package.id)
            }
        }
        walk(nil)
        // Anything left is unreachable from a root — a broken parent pointer.
        // Appended rather than dropped: a package the screen does not draw is
        // a package nobody can fix.
        result.append(contentsOf: packages.filter { !seen.contains($0.id) })
        return result
    }

    /// Moves one package to sit where another one is, among its own siblings
    /// (§19.6, P10.11).
    ///
    /// Order in a WBS is the order somebody reads the plan in, and until now it
    /// could only be changed by deleting a package and adding it again at the
    /// end — so a plan written slightly out of sequence stayed that way.
    ///
    /// Two refusals, both about not silently doing something else:
    ///
    ///  • **Only between siblings.** Dropping a package on one with a different
    ///    parent would be a re-parenting, which changes what the plan *says*
    ///    rather than the order it says it in. That is a different act and it
    ///    is not this one.
    ///  • **The whole run is renumbered.** Returning one changed row leaves the
    ///    others holding numbers that no longer describe the sequence, and the
    ///    next insert lands in the wrong place.
    ///
    /// Returns the packages whose order changed, or an empty array when the
    /// move was refused or would change nothing.
    public func reordering(_ moved: String, toPositionOf target: String) -> [WorkPackage] {
        guard moved != target,
              let source = byID[moved], let destination = byID[target],
              source.parent == destination.parent else { return [] }

        var siblings = children(of: source.parent)
        guard let from = siblings.firstIndex(where: { $0.id == moved }),
              let to = siblings.firstIndex(where: { $0.id == target }) else { return [] }

        let package = siblings.remove(at: from)
        siblings.insert(package, at: to)

        return siblings.enumerated().compactMap { index, sibling in
            guard sibling.order != index else { return nil }
            var next = sibling
            next.order = index
            return next
        }
    }

    public func depth(of package: WorkPackage) -> Int {
        var depth = 0
        var current = package
        let index = byID
        while let parentID = current.parent, let parent = index[parentID], depth < 12 {
            depth += 1
            current = parent
        }
        return depth
    }

    /// Everything wrong with the plan, in one pass. `inScope` comes from the
    /// project's scope statement: a leaf can only point at a line that is
    /// actually there, which is what stops scope creep from being invisible.
    public func problems(inScope: [String]) -> [WBSProblem] {
        let index = byID
        let scope = Set(inScope.map { $0.trimmingCharacters(in: .whitespaces) })
        var problems: [WBSProblem] = []

        for package in packages {
            if let parentID = package.parent, index[parentID] == nil {
                problems.append(.init(kind: .missingParent, packageID: package.id,
                                      title: package.title))
                continue
            }
            if reachesItself(package, index: index) {
                problems.append(.init(kind: .cycle, packageID: package.id, title: package.title))
                continue
            }
            guard isLeaf(package) else {
                // A group is only a problem when it has no leaves anywhere
                // below it — one level of nesting is not an empty heading.
                if leavesUnder(package).isEmpty {
                    problems.append(.init(kind: .emptyGroup, packageID: package.id,
                                          title: package.title))
                }
                continue
            }
            if package.acceptanceCriteria.isEmpty {
                problems.append(.init(kind: .noAcceptanceCriteria, packageID: package.id,
                                      title: package.title))
            }
            switch package.raci {
            case nil:
                problems.append(.init(kind: .noAccountable, packageID: package.id,
                                      title: package.title))
            case .some(let raci):
                // The one rule about accountability that a type cannot carry:
                // it depends on what is at stake, which is a judgement about
                // the deliverable rather than a shape (§19.9).
                if package.riskClass >= .high, !raci.accountable.isHuman {
                    problems.append(.init(kind: .highRiskWithoutHuman,
                                          packageID: package.id, title: package.title))
                }
            }

            for dependency in package.dependsOn where index[dependency] == nil {
                problems.append(.init(kind: .missingDependency, packageID: package.id,
                                      title: package.title))
                break
            }
            if dependencyCycle(from: package, index: index) {
                problems.append(.init(kind: .dependencyCycle, packageID: package.id,
                                      title: package.title))
            }

            let ref = package.scopeRef?.trimmingCharacters(in: .whitespaces)
            if ref == nil || ref?.isEmpty == true {
                problems.append(.init(kind: .noScopeRef, packageID: package.id,
                                      title: package.title))
            } else if let ref, !scope.contains(ref) {
                // The scope line was edited or removed after the leaf was
                // written. Reported rather than repaired: which one moved is
                // not something code can know.
                problems.append(.init(kind: .danglingScopeRef, packageID: package.id,
                                      title: package.title))
            }
        }
        return problems
    }

    /// Which in-scope lines have no work under them. Not an error — a plan is
    /// allowed to be unfinished — but it is the other half of the 100% rule,
    /// and G2 shows it.
    public func uncoveredScope(inScope: [String]) -> [String] {
        let covered = Set(leaves.compactMap { $0.scopeRef?.trimmingCharacters(in: .whitespaces) })
        return inScope.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !covered.contains($0) }
    }

    /// The only way a package reaches `.done`.
    ///
    /// Evidence is required because §19.15 invariant 4 says so, and because the
    /// project has watched "done" get claimed without it before: a status that
    /// can be set from anywhere is a status that will be.
    public func complete(_ packageID: String, with evidence: [Evidence]) throws -> WorkPackage {
        guard var package = byID[packageID] else {
            throw WBSError.noSuchPackage(packageID)
        }
        guard !evidence.isEmpty else {
            throw WBSError.doneWithoutEvidence(package.title)
        }
        guard isLeaf(package) else {
            throw WBSError.groupCannotBeDone(package.title)
        }
        package.status = .done
        package.evidence = evidence
        return package
    }

    private func leavesUnder(_ package: WorkPackage) -> [WorkPackage] {
        var found: [WorkPackage] = []
        for child in children(of: package.id) {
            if isLeaf(child) { found.append(child) } else { found += leavesUnder(child) }
        }
        return found
    }

    /// Depth-first over `dependsOn`. Separate from the parent-cycle check
    /// because they are different graphs over the same nodes, and a plan can
    /// be a clean tree while its dependencies wait on each other.
    private func dependencyCycle(from start: WorkPackage,
                                 index: [String: WorkPackage]) -> Bool {
        var stack = [start.id]
        var seen = Set<String>()
        while let current = stack.popLast() {
            guard let package = index[current] else { continue }
            for next in package.dependsOn {
                if next == start.id { return true }
                if seen.insert(next).inserted { stack.append(next) }
            }
        }
        return false
    }

    private func reachesItself(_ package: WorkPackage, index: [String: WorkPackage]) -> Bool {
        var seen: Set<String> = [package.id]
        var current = package
        while let parentID = current.parent, let parent = index[parentID] {
            if seen.contains(parent.id) { return true }
            seen.insert(parent.id)
            current = parent
        }
        return false
    }
}

public enum WBSError: Error, CustomStringConvertible, Equatable {
    case noSuchPackage(String)
    case doneWithoutEvidence(String)
    case groupCannotBeDone(String)

    public var description: String {
        switch self {
        case .noSuchPackage(let id): t("No work package \(id)",
                                       "Refusal message. Placeholder is the package id.")
        case .doneWithoutEvidence(let title):
            t("“\(title)” cannot be closed with no evidence — done with nothing to check is a claim",
              "Refusal message. Placeholder is the package title.")
        case .groupCannotBeDone(let title):
            t("“\(title)” is a parent — it finishes when the packages inside it do, not by being pressed",
              "Refusal message. Placeholder is the package title.")
        }
    }
}
