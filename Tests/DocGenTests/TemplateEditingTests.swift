import Testing
import Foundation
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// P7.9's outstanding half — a template could only be changed by uploading
// another file.
//
// The template is learned from a document somebody's committee accepted, so
// every section starts required and carries what the sample had under it as
// guidance. Editing it is a person disagreeing with that evidence, which they
// are entitled to do; what the type refuses is the edits that would make the
// "is anything missing" check meaningless.
// ─────────────────────────────────────────────────────────────

private let template = DocumentTemplate(
    name: "โครงร่างวิจัย คณะพยาบาล",
    sections: [
        TemplateSection(heading: "บทนำ", guidance: "ที่มาและความสำคัญ"),
        TemplateSection(heading: "วิธีดำเนินการวิจัย", guidance: "ประชากรและกลุ่มตัวอย่าง"),
        TemplateSection(heading: "ภาคผนวก", isRequired: false),
    ])

@Suite("Editing a template by hand (P7.9)")
struct TemplateEditingTests {

    @Test("renaming a heading keeps what the sample had under it")
    func renameKeepsGuidance() throws {
        let renamed = try #require(template.renaming(1, to: "ระเบียบวิธีวิจัย"))
        #expect(renamed.headings == ["บทนำ", "ระเบียบวิธีวิจัย", "ภาคผนวก"])
        // Guidance is the only record of what an accepted document had under
        // that heading, and the sample file may be long gone.
        #expect(renamed.sections[1].guidance == "ประชากรและกลุ่มตัวอย่าง")
        #expect(renamed.sections[1].isRequired)
    }

    /// A section with no heading cannot be found in the finished document, so
    /// the missing-sections check would pass it forever.
    @Test("an empty heading is refused")
    func emptyHeadingIsRefused() {
        #expect(template.renaming(0, to: "   ") == nil)
        #expect(template.renaming(9, to: "อื่น") == nil)
    }

    /// Two sections with one name is a document where "หัวข้อนี้ยังว่าง"
    /// cannot say which one.
    @Test("a duplicate heading is refused, case and space insensitively")
    func duplicateHeadingIsRefused() {
        #expect(template.renaming(1, to: "บทนำ") == nil)
        #expect(template.renaming(1, to: " บทนำ ") == nil)
        // Renaming a section to what it already is changes nothing and is not
        // an error — it is the same name, not a clash with itself.
        #expect(template.renaming(0, to: "บทนำ") != nil)
    }

    @Test("a section can stop being required, and start again")
    func requiredCanBeChanged() throws {
        let optional = try #require(template.settingRequired(0, false))
        #expect(optional.sections[0].isRequired == false)
        let back = try #require(optional.settingRequired(0, true))
        #expect(back.sections[0].isRequired)
        #expect(template.settingRequired(9, false) == nil)
    }

    @Test("a section can be moved into the order the document is read in")
    func sectionsCanBeReordered() throws {
        let moved = try #require(template.moving(2, to: 0))
        #expect(moved.headings == ["ภาคผนวก", "บทนำ", "วิธีดำเนินการวิจัย"])
        // Everything travels with the section, not just its name.
        #expect(moved.sections[0].isRequired == false)
        #expect(template.moving(0, to: 0) == nil)
        #expect(template.moving(0, to: 7) == nil)
    }

    @Test("editing never changes the template's identity")
    func identityIsStable() throws {
        let edited = try #require(template.renaming(0, to: "บทที่ 1"))
        #expect(edited.id == template.id)
        // Which matters because the export screen remembers a chosen template
        // by id, and an edit that changed it would silently unselect it.
        #expect(edited.name == template.name)
    }
}
