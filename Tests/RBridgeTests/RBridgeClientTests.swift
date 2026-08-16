import Testing
import Foundation
@testable import RBridge

// ─────────────────────────────────────────────────────────────
// P14.2's Done-when, the half that is about words: a bridge that is not
// running must produce a message that tells somebody how to start it.
//
// The reply shapes below are not invented. They are what the real bridge
// returned when it was driven on this machine against R 4.5.3 (E.28), copied
// verbatim — including the JSON `null` where R had an `NA`.
// ─────────────────────────────────────────────────────────────

@Suite("Talking to the R bridge (P14.2)")
struct RBridgeClientTests {

    /// A port nothing is listening on, which is the real condition rather than
    /// a stubbed one.
    @Test("a closed bridge says how to open it")
    func closedBridgeExplainsItself() async {
        let client = RBridgeClient(port: 8799, scriptPath: "/Users/me/r-bridge.R")
        do {
            _ = try await client.eval("1 + 1")
            Issue.record("evaluated against a bridge that is not running")
        } catch let error as RBridgeError {
            let message = error.description
            #expect(message.contains("Rscript /Users/me/r-bridge.R"))
            #expect(message.contains("ยังไม่ได้เปิด"))
            // What the person would have got instead.
            #expect(message.lowercased().contains("connection refused") == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("health on a closed bridge is a reason, not a false")
    func healthCarriesTheReason() async {
        let client = RBridgeClient(port: 8799)
        let result = await RBridgeClient(port: 8799).health()
        _ = client
        guard case .failure(let error) = result else {
            Issue.record("health said yes with nothing listening")
            return
        }
        #expect(error.description.contains("Rscript"))
    }

    /// R's message names the line and the column. Collapsing it to "the tool
    /// failed" throws away the only part that helps.
    @Test("R's own error survives the trip")
    func rErrorIsVerbatim() {
        let parseFailure = RBridgeError.codeFailed(
            "<text>:2:0: unexpected end of input\n1: sum(1,\n   ^")
        #expect(parseFailure.description.contains("unexpected end of input"))
        #expect(parseFailure.description.contains("sum(1,"))
    }

    @Test("a data frame decodes with NA kept apart from the string NA")
    func frameDecoding() throws {
        // Recorded from the live bridge (E.28).
        let json = """
        {"columns":["id","name","value"],"types":["integer","character","numeric"],
         "rows":[["1","a","1.5"],["2",null,"2.5"],["3","c","3.5"]]}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let frame = try #require(RBridgeClient.frame(from: object))

        #expect(frame.columns == ["id", "name", "value"])
        #expect(frame.types == ["integer", "character", "numeric"])
        #expect(frame.rows.count == 3)
        // The distinction the whole decoder exists for: a missing name is not
        // a name spelled "NA", and a column of country codes contains one.
        #expect(frame.rows[1][1] == nil)
        #expect(frame.rows[0][1] == "a")
    }

    @Test("a value that is not a data frame is not a failure")
    func nonFrameValuesAreFine() {
        #expect(RBridgeClient.frame(from: NSNull()) == nil)
        #expect(RBridgeClient.frame(from: nil) == nil)
        // A model object, a plot, an assignment: printed output and no frame.
        let result = REvalResult(printed: "hello from R", frame: nil)
        #expect(result.printed == "hello from R")
    }
}
