import Testing
import Foundation
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// The extractor, against hand-written pages that have exactly the problems
// real pages have. Deterministic and offline — the live check against five
// real sites is in PageFetcherTests and is opt-in.
// ─────────────────────────────────────────────────────────────

@Suite("Readability")
struct ReadabilityTests {
    private let page = """
    <html><head><title>ผลการศึกษาเรื่องอินซูลิน</title>
    <style>.ad { display: none }</style>
    <script>window.analytics = 1; var article = "ไม่ใช่เนื้อหาจริง";</script>
    </head>
    <body>
      <header><h1>เว็บไซต์ตัวอย่าง</h1></header>
      <nav><a href="/a">หน้าแรก</a> <a href="/b">เกี่ยวกับเรา</a> <a href="/c">ติดต่อ</a></nav>
      <main>
        <h2>บทนำของการศึกษา</h2>
        <p>การให้อินซูลินแบบพื้นฐานร่วมกับยากินช่วยคุมระดับน้ำตาลในเลือดได้ดีขึ้นอย่างมีนัยสำคัญ</p>
        <p>ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรังต้องปรับขนาดยาตามค่าการทำงานของไต</p>
        <div class="related"><a href="/1">บทความที่เกี่ยวข้องหนึ่ง</a> <a href="/2">บทความที่เกี่ยวข้องสอง</a></div>
        <p>สรุป: ควรติดตามค่าน้ำตาลสะสมทุกสามเดือนเพื่อประเมินผลการรักษาอย่างต่อเนื่อง</p>
      </main>
      <footer><p>สงวนลิขสิทธิ์ &copy; 2026 เว็บไซต์ตัวอย่าง ติดต่อเราได้ที่อีเมล</p></footer>
    </body></html>
    """

    @Test("the article survives and the furniture does not")
    func extractsArticleOnly() {
        let extracted = Readability().extract(html: page)

        #expect(extracted.title == "ผลการศึกษาเรื่องอินซูลิน")
        #expect(extracted.text.contains("การให้อินซูลินแบบพื้นฐาน"))
        #expect(extracted.text.contains("ควรติดตามค่าน้ำตาลสะสม"))

        // The things that make a naive extraction useless.
        #expect(!extracted.text.contains("window.analytics"))
        #expect(!extracted.text.contains("ไม่ใช่เนื้อหาจริง"), "script contents leaked in")
        #expect(!extracted.text.contains("เกี่ยวกับเรา"), "navigation leaked in")
        #expect(!extracted.text.contains("สงวนลิขสิทธิ์"), "footer leaked in")
    }

    @Test("text comes back as paragraphs, because a citation needs one")
    func paragraphsArePreserved() {
        let extracted = Readability().extract(html: page)
        // "somewhere on this page" is not a citation (§11.3).
        #expect(extracted.paragraphs.count >= 3)
        #expect(extracted.paragraphs.allSatisfy { !$0.contains("\n\n") })
    }

    @Test("a link rail is dropped even when it uses paragraph tags")
    func linkHeavyBlocksAreDropped() {
        let html = """
        <body><p><a href="/1">ข่าวหนึ่งที่ยาวพอสมควรจนผ่านเกณฑ์ความยาว</a>
        <a href="/2">ข่าวสองที่ยาวพอสมควรเช่นกันจนผ่านเกณฑ์</a></p>
        <p>เนื้อหาจริงของบทความนี้พูดถึงการรักษาผู้ป่วยเบาหวานด้วยอินซูลินอย่างละเอียด</p></body>
        """
        let extracted = Readability().extract(html: html)
        #expect(extracted.paragraphs.count == 1)
        #expect(extracted.paragraphs[0].contains("เนื้อหาจริง"))
    }

    @Test("entities are decoded, including numeric Thai")
    func entitiesAreDecoded() {
        // A page encoding Thai numerically is unreadable otherwise — and
        // unreadable text that gets indexed is worse than a failed fetch.
        let html = "<p>&#3585;&#3634;&#3619;&#3623;&#3636;&#3592;&#3633;&#3618; &amp; &#x0E01;&#x0E32;&#x0E23;&#x0E28;&#x0E36;&#x0E01;&#x0E29;&#x0E32;เรื่องการให้อินซูลินในผู้ป่วยเบาหวานชนิดที่สอง</p>"
        let extracted = Readability().extract(html: html)
        #expect(extracted.paragraphs.first?.contains("การวิจัย") == true,
                "got \(extracted.paragraphs)")
        #expect(extracted.paragraphs.first?.contains("&") == true)
    }

    @Test("line breaks between sentences are kept")
    func lineBreaksBecomeSpaces() {
        let html = "<p>ประโยคแรกของย่อหน้านี้ยาวพอที่จะผ่านเกณฑ์<br>ประโยคที่สองต่อจากนั้นทันที</p>"
        let text = Readability().extract(html: html).text
        // Without handling <br> the two run together into one word.
        #expect(!text.contains("เกณฑ์ประโยคที่สอง"), "got \(text)")
    }

    @Test("a page with nothing to say returns nothing rather than noise")
    func emptyPageIsEmpty() {
        let extracted = Readability().extract(html: "<html><body><nav><a href=/>เมนู</a></nav></body></html>")
        #expect(extracted.isEmpty)
    }

    @Test("a repeated lead paragraph is not quoted twice")
    func duplicateBlocksAreCollapsed() {
        let sentence = "การให้อินซูลินแบบพื้นฐานร่วมกับยากินช่วยคุมระดับน้ำตาลได้ดีขึ้น"
        let html = "<div class=summary><p>\(sentence)</p></div><article><p>\(sentence)</p></article>"
        #expect(Readability().extract(html: html).paragraphs.count == 1)
    }
}
