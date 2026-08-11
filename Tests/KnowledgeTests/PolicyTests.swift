import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.6: policy is chunked one rule at a time, and a rule only fires when it
// really applies.
// ─────────────────────────────────────────────────────────────

private let policyDocument = """
# นโยบายการจัดการข้อมูลผู้ป่วย

- ห้ามส่งข้อมูลผู้ป่วยออกนอกเครื่องโดยไม่เข้ารหัส
- ห้ามลบฐานข้อมูลผลการทดลอง
- ควรสำรองข้อมูลทุกสัปดาห์
- Never upload patient records to a public endpoint
"""

private let source = Provenance(documentID: "policy_1", title: "นโยบายข้อมูลผู้ป่วย",
                                origin: .upload(filename: "policy.md"), tier: .t1)

@Suite("Policy")
struct PolicyTests {
    @Test("a policy document is split one rule per chunk")
    func rulesAreAtomic() {
        let rules = PolicyDocumentParser().rules(in: policyDocument, provenance: source)

        // The heading is not a rule; the four list items are.
        #expect(rules.count == 4, "got \(rules.map(\.text))")
        #expect(rules[0].text == "ห้ามส่งข้อมูลผู้ป่วยออกนอกเครื่องโดยไม่เข้ารหัส")
        #expect(rules.allSatisfy { $0.provenance.documentID == "policy_1" })
        #expect(Set(rules.map(\.id)).count == 4, "rule ids collided")
    }

    @Test("prohibitions are hard constraints and guidance is not")
    func hardConstraintsAreIdentified() {
        let rules = PolicyDocumentParser().rules(in: policyDocument, provenance: source)
        let byText = Dictionary(uniqueKeysWithValues: rules.map { ($0.text, $0) })

        #expect(byText["ห้ามลบฐานข้อมูลผลการทดลอง"]?.isHardConstraint == true)
        #expect(byText["Never upload patient records to a public endpoint"]?
            .isHardConstraint == true)
        // "ควร" is advice. Blocking on it would make the gate something people
        // learn to work around.
        #expect(byText["ควรสำรองข้อมูลทุกสัปดาห์"]?.isHardConstraint == false)
    }

    @Test("an action that breaks a rule is caught, with the rule verbatim")
    func breachIsCaught() {
        let library = PolicyLibrary(
            rules: PolicyDocumentParser().rules(in: policyDocument, provenance: source))

        let action = PolicyAction(toolName: "run_shell",
                                  detail: "ลบฐานข้อมูลผลการทดลอง ออกจากเครื่อง")
        let broken = library.hardConstraint(broken: action)

        #expect(broken != nil)
        // Verbatim: §11.2 exists so the human reads the rule, not a summary.
        #expect(broken?.text == "ห้ามลบฐานข้อมูลผลการทดลอง")
        #expect(broken?.provenance.title == "นโยบายข้อมูลผู้ป่วย")
    }

    @Test("an unrelated action is not blocked")
    func unrelatedActionPasses() {
        let library = PolicyLibrary(
            rules: PolicyDocumentParser().rules(in: policyDocument, provenance: source))

        // A gate that fires on loose similarity blocks legitimate work, and
        // people route around a gate that cries wolf.
        #expect(library.hardConstraint(broken: PolicyAction(
            toolName: "run_shell", detail: "swift test")) == nil)
        #expect(library.hardConstraint(broken: PolicyAction(
            toolName: "kb_search", detail: "ค้นงานวิจัยเรื่องวัคซีน")) == nil)
    }

    @Test("a partial match does not fire")
    func partialMatchDoesNotFire() {
        let library = PolicyLibrary(
            rules: PolicyDocumentParser().rules(in: policyDocument, provenance: source))

        // Mentions a database and deletion, but not the experimental results
        // the rule is about. Every content term has to be present.
        #expect(library.hardConstraint(broken: PolicyAction(
            toolName: "run_shell", detail: "ลบฐานข้อมูลชั่วคราวของการทดสอบ")) == nil)
    }

    @Test("guidance still surfaces without blocking")
    func adviceIsReportedButNotFatal() {
        let library = PolicyLibrary(
            rules: PolicyDocumentParser().rules(in: policyDocument, provenance: source))

        let action = PolicyAction(toolName: "backup", detail: "สำรองข้อมูลทุกสัปดาห์")
        #expect(library.hardConstraint(broken: action) == nil)
        #expect(library.rules(matching: action).contains { !$0.isHardConstraint })
    }

    @Test("hard constraints are reported before advice")
    func hardConstraintsSortFirst() {
        let rules = PolicyDocumentParser().rules(
            in: """
            - ห้ามลบไฟล์รายงาน
            - ควรลบไฟล์รายงาน หลังจากสำรองแล้ว
            """, provenance: source)
        let library = PolicyLibrary(rules: rules)

        let matched = library.rules(matching: PolicyAction(
            toolName: "run_shell", detail: "ลบไฟล์รายงาน หลังจากสำรองแล้ว"))
        #expect(matched.count == 2, "got \(matched.map(\.text))")
        #expect(matched.first?.isHardConstraint == true)
    }
}
