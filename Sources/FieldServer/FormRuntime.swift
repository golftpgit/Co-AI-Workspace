import Foundation
import Instruments

// ─────────────────────────────────────────────────────────────
// A published instrument, as a web page (ARCHITECTURE §20.7).
//
// Plain HTML, one inline stylesheet, one inline script, no framework and no
// external request of any kind. Three reasons, in order of how much they matter:
//
//  1. The people filling this in are on a hospital wifi with a five-year-old
//     phone. A page that needs to fetch 200KB of JavaScript before the first
//     question appears is a page with a response rate problem.
//  2. The server has no internet-facing side and no CDN to trust.
//  3. Every element here is a native form control, which is what makes the form
//     work with a keyboard and a screen reader without anybody writing ARIA for
//     a custom widget.
//
// The consent page comes first and it is not a checkbox with no text: §20.5 says
// the gate reads the words, and this is where the words are shown. Which wording
// a respondent saw is recorded with their answers, because consent given to an
// earlier wording is not consent to a later one.
// ─────────────────────────────────────────────────────────────

public enum FormRuntime {

    /// The whole form as one page: consent, then the questions, then submit.
    public static func page(for published: PublishedInstrument,
                            wave: String,
                            notice: String? = nil) -> String {
        let instrument = published.instrument
        let items = instrument.ordered
        var body = ""

        if let notice {
            body += "<p class=\"notice\" role=\"status\">\(htmlEscaped(notice))</p>\n"
        }

        body += consentSection(instrument)
        body += "<ol class=\"items\">\n"
        for item in items {
            body += itemSection(item, in: instrument)
        }
        body += "</ol>\n"

        body += """
        <div class="actions">
          <button type="submit" class="submit">ส่งคำตอบ</button>
        </div>
        """

        return document(title: instrument.title.thai,
                        version: instrument.version,
                        wave: wave,
                        instrumentID: instrument.id,
                        body: body)
    }

    /// What a respondent sees after submitting. No answers are echoed back: this
    /// page is reachable by anyone with the link, so it says that something was
    /// received and nothing about what.
    public static func thanks(for published: PublishedInstrument) -> String {
        document(title: published.instrument.title.thai,
                 version: published.instrument.version,
                 wave: "",
                 instrumentID: published.instrument.id,
                 body: """
                 <p class="thanks">บันทึกคำตอบเรียบร้อยแล้ว ขอบคุณที่สละเวลา</p>
                 <p class="muted">ถ้าต้องการถอนคำตอบหรือสอบถามเพิ่มเติม ติดต่อผู้วิจัยตามช่องทางในหน้าความยินยอม</p>
                 """,
                 showsForm: false)
    }

    public static func message(title: String, text: String) -> String {
        document(title: title, version: 0, wave: "", instrumentID: "",
                 body: "<p class=\"notice\">\(htmlEscaped(text))</p>", showsForm: false)
    }

    // MARK: - pieces

    private static func consentSection(_ instrument: Instrument) -> String {
        guard let consent = instrument.consent else { return "" }
        return """
        <section class="consent" aria-labelledby="consent-heading">
          <h2 id="consent-heading">ความยินยอมในการเข้าร่วม</h2>
          <dl>
            <dt>วัตถุประสงค์</dt><dd>\(htmlEscaped(consent.purpose.thai))</dd>
            <dt>ข้อมูลที่เก็บ</dt><dd>\(htmlEscaped(consent.whatIsCollected.thai))</dd>
            <dt>ความสมัครใจ</dt><dd>\(htmlEscaped(consent.voluntary.thai))</dd>
            <dt>ติดต่อผู้วิจัย</dt><dd>\(htmlEscaped(consent.contact))</dd>
          </dl>
          <p class="agree">
            <label>
              <input type="checkbox" name="__consent" value="yes" required>
              ข้าพเจ้าอ่านข้อความข้างต้นแล้วและยินยอมเข้าร่วม
            </label>
          </p>
        </section>

        """
    }

    private static func itemSection(_ item: Item, in instrument: Instrument) -> String {
        let name = htmlEscaped(item.id)
        let prompt = htmlEscaped(item.prompt.thai)
        let required = item.required ? " required" : ""
        // The skip condition travels to the page as data on the element, so the
        // inline script needs no per-item generated code and the server can check
        // exactly the same rule.
        var attributes = " id=\"q-\(name)\""
        if let skip = item.skip {
            attributes += " data-skip-item=\"\(htmlEscaped(skip.itemID))\""
            attributes += " data-skip-test=\"\(skip.test.rawValue)\""
            attributes += " data-skip-value=\"\(htmlEscaped(skip.value))\""
        }

        var control = ""
        switch item.kind {
        case .likert(let levels):
            control = choices(name: name, options: levels, multiple: false,
                              required: item.required, valuesAreOrdinals: true)
        case .single(let options):
            control = choices(name: name, options: options, multiple: false,
                              required: item.required, valuesAreOrdinals: false)
        case .multiple(let options, _):
            control = choices(name: name, options: options, multiple: true,
                              required: false, valuesAreOrdinals: false)
        case .openText(let maximum):
            let limit = maximum.map { " maxlength=\"\($0)\"" } ?? ""
            control = "<textarea name=\"\(name)\" rows=\"3\"\(limit)\(required)></textarea>"
        case .number(let minimum, let maximum):
            var bounds = ""
            if let minimum { bounds += " min=\"\(minimum)\"" }
            if let maximum { bounds += " max=\"\(maximum)\"" }
            control = "<input type=\"number\" inputmode=\"numeric\" name=\"\(name)\"\(bounds)\(required)>"
        case .date:
            control = "<input type=\"date\" name=\"\(name)\"\(required)>"
        case .matrix, .ranking, .fileUpload:
            // Types the model has and this runtime has not learned to draw.
            // Rendered as an honest gap rather than as something that looks like
            // a question and collects nothing (§20.3's rule, applied to the
            // renderer): the instrument gate cannot catch this, so the page says
            // it out loud.
            control = "<p class=\"unsupported\">ข้อชนิด “\(htmlEscaped(item.kind.label))” "
                + "ยังแสดงบนเว็บฟอร์มไม่ได้ — ติดต่อผู้วิจัย</p>"
        }

        let help = item.help.map { "<p class=\"help\">\(htmlEscaped($0.thai))</p>" } ?? ""
        let legend = item.required ? "\(prompt) <span class=\"req\" aria-hidden=\"true\">*</span>" : prompt
        let requiredNote = item.required ? "<span class=\"sr-only\">จำเป็นต้องตอบ</span>" : ""
        _ = instrument
        return """
        <li class="item"\(attributes)>
          <fieldset>
            <legend>\(legend)\(requiredNote)</legend>
            \(help)
            \(control)
          </fieldset>
        </li>

        """
    }

    private static func choices(name: String, options: [Bilingual], multiple: Bool,
                                required: Bool, valuesAreOrdinals: Bool) -> String {
        var html = "<div class=\"choices\">"
        for (index, option) in options.enumerated() {
            let value = valuesAreOrdinals ? "\(index + 1)" : option.thai
            let type = multiple ? "checkbox" : "radio"
            // `required` on the first radio of a group is what makes the browser
            // enforce the group; on checkboxes it would demand every box.
            let requiredAttribute = (required && !multiple && index == 0) ? " required" : ""
            html += """
            <label class="choice">
              <input type="\(type)" name="\(name)" value="\(htmlEscaped(value))"\(requiredAttribute)>
              <span>\(htmlEscaped(option.thai))</span>
            </label>
            """
        }
        return html + "</div>"
    }

    private static func document(title: String, version: Int, wave: String,
                                 instrumentID: String, body: String,
                                 showsForm: Bool = true) -> String {
        let form = showsForm
            ? """
              <form method="post" action="/submit" novalidate="false">
                <input type="hidden" name="__instrument" value="\(htmlEscaped(instrumentID))">
                <input type="hidden" name="__version" value="\(version)">
                <input type="hidden" name="__wave" value="\(htmlEscaped(wave))">
              \(body)
              </form>
              """
            : body

        return """
        <!doctype html>
        <html lang="th">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex, nofollow">
        <title>\(htmlEscaped(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <main>
        <h1>\(htmlEscaped(title))</h1>
        \(version > 0 ? "<p class=\"muted\">เวอร์ชัน \(version)</p>" : "")
        \(form)
        </main>
        \(showsForm ? "<script>\(script)</script>" : "")
        </body>
        </html>
        """
    }

    /// One stylesheet, sized for a phone first. `prefers-color-scheme` because a
    /// night-shift nurse answering at 3am should not get a white flash.
    private static let stylesheet = """
    :root { color-scheme: light dark; --line: #d8d8dc; --muted: #6b6b70; --accent: #1f6feb; }
    @media (prefers-color-scheme: dark) { :root { --line: #3a3a3e; --muted: #9a9aa0; --accent: #6ea8ff; } }
    * { box-sizing: border-box; }
    body { margin: 0; font: 16px/1.6 -apple-system, "Helvetica Neue", "Sarabun", sans-serif; }
    main { max-width: 42rem; margin: 0 auto; padding: 1.25rem 1rem 4rem; }
    h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
    h2 { font-size: 1.05rem; margin: 0 0 .5rem; }
    .muted, .help { color: var(--muted); font-size: .875rem; }
    .consent { border: 1px solid var(--line); border-radius: .5rem; padding: 1rem; margin: 1rem 0; }
    .consent dt { font-weight: 600; margin-top: .5rem; }
    .consent dd { margin: 0 0 .25rem; }
    .agree { margin-top: 1rem; }
    ol.items { list-style: none; padding: 0; margin: 0; counter-reset: q; }
    .item { border-top: 1px solid var(--line); padding: 1rem 0; }
    .item[hidden] { display: none; }
    fieldset { border: 0; margin: 0; padding: 0; }
    legend { font-weight: 600; padding: 0; margin-bottom: .5rem; }
    .req { color: #c0392b; }
    .choices { display: flex; flex-direction: column; gap: .35rem; }
    .choice { display: flex; align-items: flex-start; gap: .5rem; padding: .35rem .25rem;
              border-radius: .35rem; cursor: pointer; }
    .choice:hover { background: color-mix(in srgb, currentColor 6%, transparent); }
    input[type=text], input[type=number], input[type=date], textarea {
        width: 100%; padding: .5rem; font: inherit; border: 1px solid var(--line);
        border-radius: .35rem; background: transparent; color: inherit; }
    /* 44px is the smallest thing a thumb hits reliably. */
    input[type=radio], input[type=checkbox] { width: 1.15rem; height: 1.15rem; margin-top: .2rem; }
    .choice, .submit { min-height: 44px; }
    .actions { margin-top: 1.5rem; }
    .submit { font: inherit; padding: .75rem 1.5rem; border: 0; border-radius: .5rem;
              background: var(--accent); color: #fff; cursor: pointer; width: 100%; }
    .notice { border: 1px solid var(--line); border-left: 4px solid var(--accent);
              padding: .75rem 1rem; border-radius: .35rem; }
    .unsupported { color: #c0392b; }
    .thanks { font-size: 1.1rem; }
    .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
    :focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
    """

    /// Skip logic, client side. It hides questions that do not apply — and the
    /// server checks the same rule again, because a hidden field is hidden only
    /// in the browser that chose to hide it.
    private static let script = """
    (function () {
      var items = Array.prototype.slice.call(document.querySelectorAll('.item[data-skip-item]'));
      function valueOf(name) {
        var nodes = document.getElementsByName(name);
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          if (node.type === 'radio' || node.type === 'checkbox') {
            if (node.checked) return node.value;
          } else if (node.value !== '') return node.value;
        }
        return null;
      }
      function shows(item) {
        var current = valueOf(item.getAttribute('data-skip-item'));
        var wanted = item.getAttribute('data-skip-value');
        if (current === null) return false;
        switch (item.getAttribute('data-skip-test')) {
          case 'equals': return current === wanted;
          case 'notEquals': return current !== wanted;
          case 'atLeast': return parseFloat(current) >= parseFloat(wanted);
          case 'atMost': return parseFloat(current) <= parseFloat(wanted);
        }
        return true;
      }
      function apply() {
        items.forEach(function (item) {
          var visible = shows(item);
          item.hidden = !visible;
          // A hidden question must not block submission by still being required.
          Array.prototype.forEach.call(item.querySelectorAll('input, textarea, select'),
            function (field) { field.disabled = !visible; });
        });
      }
      document.addEventListener('change', apply);
      document.addEventListener('input', apply);
      apply();
    })();
    """
}
