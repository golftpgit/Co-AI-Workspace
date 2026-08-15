import Testing
import Foundation
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// P15.5/P15.6 — the busy light is read from the server, never claimed.
//
// The bodies below are the real shape of vLLM 0.27.1's `/metrics`, kept short:
// what matters is that the parser takes the two gauges it came for and ignores
// everything else, including the comment lines that repeat the same names.
// ─────────────────────────────────────────────────────────────

private let realistic = """
# HELP vllm:num_requests_running Number of requests currently running on GPU.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{engine="0",model_name="unsloth/Qwen3.8-27B-NVFP4"} 3.0
# HELP vllm:num_requests_waiting Number of requests waiting to be processed.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting{engine="0",model_name="unsloth/Qwen3.8-27B-NVFP4"} 1.0
# HELP vllm:gpu_cache_usage_perc GPU KV-cache usage. 1 means 100 percent usage.
# TYPE vllm:gpu_cache_usage_perc gauge
vllm:gpu_cache_usage_perc{engine="0",model_name="unsloth/Qwen3.8-27B-NVFP4"} 0.12
"""

@Suite("Reading how busy the server is")
struct ServerLoadTests {

    @Test("the two gauges are taken and the rest of the format is left alone")
    func parsesTheGauges() {
        let load = ServerLoad.parse(realistic)
        #expect(load == ServerLoad(running: 3, waiting: 1))
        #expect(load?.total == 4)
        #expect(load?.isIdle == false)
    }

    // The comment lines carry the same metric names as the samples. A parser
    // that matches on the name alone reads `# TYPE …gauge` and takes "gauge"
    // for a number — or worse, takes the HELP line's last word as the count.
    @Test("comment lines are not samples")
    func ignoresComments() {
        let commentsOnly = """
            # HELP vllm:num_requests_running Number of requests currently running on GPU.
            # TYPE vllm:num_requests_running gauge
            """
        #expect(ServerLoad.parse(commentsOnly) == nil)
    }

    // An idle server and a server that cannot be seen are different facts, and
    // a screen that shows a confident 0 for the second one is claiming
    // something nobody checked — the exact failure §2.5 is about.
    @Test("no metrics at all is nil, not idle")
    func silenceIsNotIdle() {
        #expect(ServerLoad.parse("# nothing here\n") == nil)
        #expect(ServerLoad.parse("vllm:num_requests_running{m=\"x\"} 0.0")
                == ServerLoad(running: 0, waiting: 0))
        #expect(ServerLoad.parse("vllm:num_requests_running{m=\"x\"} 0.0")?.isIdle == true)
    }

    @Test("metrics live beside /v1, not under it")
    func metricsPathIsSiblingOfV1() {
        // Got this wrong once by hand: `…:8000/v1/metrics` answers 404 and the
        // busy light silently stays nil, which reads as "server not reporting".
        let reader = ServerLoadReader(baseURL: URL(string: "http://gx10:8000/v1")!)
        #expect("\(Mirror(reflecting: reader).children.first?.value ?? "")"
                .contains("http://gx10:8000/metrics"))
    }
}
