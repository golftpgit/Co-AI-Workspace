# Spike — bge-m3 in our own process (2026-08-11)

**Question**: must the knowledge base depend on LM Studio, or can the app own its
embedding model the way it already owns the SurrealDB sidecar?
([ARCHITECTURE](../../ARCHITECTURE.md) line 1256 says it must be ours — nobody had
checked whether that is possible in Swift today.)

**Answer**: the Swift side is ready. The build is not — and the blocker is the
*build system*, not the model.

## What works

| | |
|---|---|
| `MLXEmbedders` (in [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) 3.31.4, pushed 2026-08-10) | ships `EmbedderRegistry.bge_m3` and a BERT port — bge-m3 is a first-class configuration, not something we would port ourselves |
| `mlx-community/bge-m3-mlx-*` on Hugging Face | fp16 / 8bit / 6bit / 4bit all published |
| The adapter layer | mlx-swift-lm deliberately ships **no** downloader and **no** tokenizer — they are protocols the host supplies. `Hub` and `Tokenizers` from swift-transformers fill both in ~40 lines (`main.swift`), including a bridge between the two `Tokenizer` protocols |
| Compiling our spike | `swift build` succeeds |

## What blocks it

**1. This machine has no Metal Toolchain.**

```
$ xcodebuild -showComponent MetalToolchain
Status: uninstalled

$ xcrun metal --version
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
```

Xcode 26 makes the Metal compiler a downloadable component. Without it MLX's
kernels cannot be compiled, and at runtime MLX fails with
`Failed to load the default metallib`. Fixable with one command — but it is a
multi-gigabyte install, so it is the user's call, and it is now a documented
prerequisite for anyone building this project with MLX in it.

**2. Even with the toolchain, MLX cannot be built the way this project builds.**

mlx-swift's own README:

> SwiftPM (command line) cannot build the Metal shaders so the ultimate build
> has to be done via Xcode.

`scripts/check.sh` and `scripts/build-app.sh` are SwiftPM by an explicit
architectural choice — `build-app.sh` says so in its header: *"Kept as a script
(not an .xcodeproj) so the whole build is reproducible from the command line and
in CI."* Adopting MLX in-process means giving that up, or carrying an
`xcodebuild` step that exists only to produce one `.metallib`.

## Options, in the order they should be considered

**A. Bundle our own inference sidecar** (`llama-server` + bge-m3 GGUF), managed by
`SidecarManager` exactly like `surreal`. Gets the actual goal — the model lives in
the app's container, we pin its version, LM Studio is gone — and changes nothing
about how the project builds. Costs a second sidecar binary and an HTTP hop that
`RemoteEmbedder` already speaks.

**B. MLX in-process, with an `xcodebuild` step** for the metallib, kept out of the
main build. Best runtime story (no process, no HTTP, shared memory), but it
reopens a decision that was made deliberately, and it needs the Metal Toolchain
installed on every build machine.

**C. Stay on LM Studio.** Rejected: the KB's correctness depends on a model owned
by an app we do not control, which the user can update or delete, and which the
App Sandbox forbids us from even reading off disk (only HTTP on localhost works).

**Recommendation: A now, B when the sandbox and build story are worth revisiting.**
Option A is a sidecar we already know how to run and reaches the same end state
for the thing that actually matters: the embedding model becomes ours, pinned,
and versioned with the index profile.

## Reproducing

```bash
cd spikes/EmbeddingRuntime
swift build                # compiles
swift run EmbeddingRuntimeSpike   # fails: no default.metallib
```

The spike's five checks (load, 1024 dimensions, reads Thai, agrees with the GGUF
build LM Studio serves, throughput) are written and compile — they have not been
*run*, because none of them can execute without the Metal toolchain. Nothing in
this file claims a measurement that was not taken.
