# Scaffold the Zig harness-to-file exporter

Assisted-by: OpenCode · Hy4 Flash <opencode-opencodego-hy4flash@local>

> Prompts: [1795344704000-scaffold-zig-exporter.prompts.md](1795344704000-scaffold-zig-exporter.prompts.md)

Status: implemented

## Context

The Dorothy `ai-sync` command imported TypingMind JSON into AnythingLLM's SQLite database. It has no Open WebUI code, and the local Open WebUI database held zero chats, no vector embeddings, and no backup copies. The user removed Open Web UI after that confirmation.

The replacement must not import into any harness. It only exports harness chats to files under `~/Documents/AI`: a Markdown pair with prompts and answers, a JSON pair with all metadata, and attachments copied into an `attachments` directory.

The Bevry `policy.md` skill blocked the work until `agent-detect` could identify this session. The local `zig-out` binary was stale (19 Nov) relative to its source (22 Nov); `./scripts/zig build` in `agent-detect` restored live detection of `opencode` / `opencode-go` / `hy4-flash` and `check-reciprocal` exited 0.

## Change

### Architecture decision

| Option | What it would mean | Verdict |
| --- | --- | --- |
| Port the Dorothy TypeScript command | Reuse TypingMind/AnythingLLM importer code | Rejected — user explicitly forbids replication; wrong direction |
| Depend on `agent-detect` as a Zig module | Requires upstream to export a library artifact and a published package hash | Deferred — upstream currently exports only a `build_options` module; no session library exists |
| Follow agent-detect's session-store paths and Zig conventions in this repo | Table-driven readers plus local normalisation | Chosen — no upstream changes, read-only stores, easy to extend |

The chosen design keeps all store access in `src/lib/readers.zig`. Each harness is one table row: a JSON/JSONL tree path or a SQLite database with two SQL templates. Message-shape differences are isolated in `src/lib/normalize.zig`; output lives in `src/lib/render.zig`.

### File schema

- `<stamp>-<harness>-<title>.md` — numbered `Prompt` / `Answer` sections only, no metadata.
- `<stamp>-<harness>-<title>.json` — `schema`, `session` (id, title, harness, provider, model, cwd, source path, stamp), `counts`, `attachments`, and every message with role, time, and content.
- `attachments/<stamp>-<harness>-<attachment>.<ext>` — copied from paths found in attachment-like fields, only when the file exists.
- `.ai-export-sync-manifest.tsv` — source path, Wyhash of messages and attachments, and the two output paths. A matching hash leaves the pair untouched; a changed pair is removed before being rewritten.

### Code impact

| File | Purpose |
| --- | --- |
| `build.zig`, `build.zig.zon`, `scripts/zig*` | Zig 0.17 build, pinned compiler, test and cross-compile steps |
| `src/main.zig` | CLI parsing, discovery orchestration, summary |
| `src/lib/model.zig` | Session types, slugs, UTC stamps, content hashing |
| `src/lib/readers.zig` | Harness registry and read-only store access |
| `src/lib/normalize.zig` | Role detection, block-array flattening, attachment discovery |
| `src/lib/render.zig` | Markdown, JSON, attachment copies, manifest |
| `src/normalize.test.zig` | Slug, stamp, message, and attachment tests |
| `AGENTS.md`, `README.md`, `LICENSE.md`, base configs, CI | Bevry scaffold |

### Known gaps

OpenCode's current SQLite store keeps message summaries and metadata but not full prompt text in the `message.data` rows, so those sessions are discovered and skipped rather than exported as empty files. Zed's zstd thread blobs, Crush, and Copilot CLI databases are not covered in this first pass.

## Verification

- `./scripts/zig build test` — five unit tests pass.
- `./scripts/zig build` — native binary compiles.
- `ai-export-sync --dry-run` — discovers 558 sessions, skips 304 metadata-only OpenCode sessions, reports no failures.
- `ai-export-sync --output=<temp>` — writes 254 Markdown/JSON pairs from cline, codex, codewhale, dsh, and zcode stores; sample Markdown contains only prompt/answer turns.
- `agent-detect identify` and `check-reciprocal` — pass after rebuilding agent-detect.
