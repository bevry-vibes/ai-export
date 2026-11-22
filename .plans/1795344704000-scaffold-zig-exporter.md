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

- `<harness>/<yyyy-mm-dd hh-mm> - <session-id> - <title>.md` — `Prompt` / `Answer` turns only, no metadata.
- `<harness>/<yyyy-mm-dd hh-mm> - <session-id> - <title>.json` — `schema`, `session` (id, title, harness, provider, model, cwd, source path, stamp), `counts`, `attachments`, and every message with role, time, and content.
- `<harness>/attachments/<yyyy-mm-dd hh-mm> - <session-id> - <attachment>.<ext>` — copied from paths found in attachment-like fields, only when the file exists.
- Every run wipes previous generated files first; there is no incremental manifest. This keeps one generation of output on disk.

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

Coverage now includes OpenCode v2 `session_message` plus legacy `part` rows, Kilo, AnythingLLM, Goose, Crush, Copilot's VS Code store, Cline, CodeWhale, Codex, zstd-compressed DSH, ZCode, Pi, Qwen, and Reasonix. Claude Desktop's IndexedDB store and Copilot CLI's empty-window JSONL are not covered.

## Verification

- `./scripts/zig build test` — five unit tests pass.
- `./scripts/zig build` — native binary compiles.
- `ai-export --dry-run` — discovers 1449 sessions, skips 9, reports no failures.
- `ai-export --output=<temp>` — writes human-readable per-harness pairs using source timestamps and short session ids; sample Markdown contains only prompt/answer turns.
- A second run wipes and rewrites the same set, leaving one generation of files.
- `agent-detect identify` and `check-reciprocal` — pass after rebuilding agent-detect.
