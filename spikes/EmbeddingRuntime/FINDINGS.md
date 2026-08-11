# Spike — bge-m3 in our own process (2026-08-11)

**Question**: must the knowledge base depend on LM Studio, or can the app own its
embedding model the way it already owns the SurrealDB sidecar?

**Answer: yes, it runs — and the run turned up a trap worth more than the spike.**

## Results (measured, on this machine)

```
== bge-m3 in-process spike ==
  ok   load bge-m3 through MLXEmbedders (43.28s) 3 vectors, 1024 dims, embed took 1.26s
  ok   dimensions are the 1024 P2.1 locked
  ok   it can read Thai            related 0.764 vs unrelated 0.379
  ok   agrees with the GGUF build LM Studio serves
       cosine per sentence: -0.0008, -0.0068, 0.0512
  ok   throughput                  32 chunks in 0.14s (232 chunks/s)
```

- **1024 dimensions**, matching what P2.1 locked.
- **Reads Thai properly** — 0.764 for a related sentence against 0.379 for an
  unrelated one, unlike the nomic build in E.11 that returned one constant vector.
- **232 chunks/second**, so a 10,000-chunk re-embed is well under a minute of
  compute. First load costs ~43s including the weight download.

## The finding that matters

**Two builds of "bge-m3" produce orthogonal vector spaces.** The MLX conversion
and the GGUF build LM Studio serves agree on *nothing*: cosine −0.0008, −0.0068,
0.0512 for the same three sentences. Not "slightly different" — unrelated.

Anyone treating the model name as the thing that matters would swap one for the
other, keep the same index, and destroy it silently: search would keep working
and rank noise. This is exactly what `EmbeddingProfile.revision` exists to catch,
and it is no longer a hypothetical.

## What it took to get there

Three separate blockers, none of them the model:

1. **Metal Toolchain missing.** Xcode 26 makes the Metal compiler a downloadable
   component. Without it MLX dies at `Failed to load the default metallib`.
   `xcodebuild -downloadComponent MetalToolchain` fixes it — a build-machine
   prerequisite now, for anyone building this project with MLX in it.
2. **SwiftPM cannot build Metal shaders.** mlx-swift says so itself; the build has
   to run through `xcodebuild`. `scripts/check.sh` and `scripts/build-app.sh` are
   SwiftPM by an explicit architectural choice, so adopting MLX means carrying an
   `xcodebuild` step whose only job is producing one `.metallib`.
3. **`EmbedderRegistry.bge_m3` does not load.** It points at `BAAI/bge-m3`, whose
   safetensors use Hugging Face layer names; the BERT port expects MLX-converted
   ones and fails with `keyNotFound(["encoder","layers","0","ln2","weight"])`.
   `mlx-community/bge-m3-mlx-8bit` works. The registry entry being wrong for the
   model it names is worth knowing before trusting other entries in it.

The adapter layer mlx-swift-lm leaves to the host — a `Downloader` and a
`TokenizerLoader` — is about forty lines over swift-transformers' `Hub` and
`Tokenizers`, including a bridge between the two `Tokenizer` protocols. That code
is in `main.swift` and is roughly what ships.

## Reproducing

```bash
xcodebuild -downloadComponent MetalToolchain      # once per machine
cd spikes/EmbeddingRuntime
xcodebuild -scheme EmbeddingRuntimeSpike -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .xcbuild -skipPackagePluginValidation -skipMacroValidation build
./.xcbuild/Build/Products/Debug/EmbeddingRuntimeSpike
```
