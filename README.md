# ai-export

Export AI harness chats to plain Markdown and JSON files on disk — one file pair per session, organised by harness, with attachments copied alongside.

The tool reads harness session stores read-only. It never writes back to a harness, never imports conversations into another harness, and never needs an API key.

## Why

The old Dorothy `ai-sync` command imported TypingMind JSON exports into AnythingLLM's SQLite database. That direction is gone. This project only exports harness chats to files, so the result is portable, greppable, and independent of any vendor's import format.

Harness discovery follows [agent-detect](https://github.com/bevry-vibes/agent-detect)'s session-store paths and Zig conventions. `agent-detect` remains the source of truth for which harnesses exist and where they keep their sessions; this project adds the transcript-reading and file-rendering half.

## Requirements

- Zig 0.17.0 (installed into the gitignored `vendor/zig/` on first `./scripts/zig` call)
- `sqlite3` on PATH for database-backed harnesses

## Usage

```sh
./scripts/zig build                          # build into zig-out/bin
./zig-out/bin/ai-export --dry-run            # discover sessions, write nothing
./zig-out/bin/ai-export                      # export everything into ~/Documents/AI
./zig-out/bin/ai-export --output=~/Documents/AI --harness=opencode
./zig-out/bin/ai-export --version
```

Options: `--output=<dir>` changes the destination; `--harness=<id>` limits the run to one harness; `--import-archives` rebuilds from all installed harness stores **and** every archive under `archives/` (a single full rebuild, with harness directories deleted first); `--no-title-generation` skips `fm respond` summaries; `--archive=<path>` ingests an ad-hoc external export (repeatable); `--kagi` fetches Kagi Assistant chats using the `KAGI_SESSION` cookie from the environment; `--kagi-share=<id>` fetches one public Kagi share; `--include-noise` keeps agent-detect fixtures-capture sessions; `--dry-run` reports without writing; `--help` prints all options.

Agent-detect noise is filtered out by default. The capture phrase `in the current working directory and report the result` appears in both the static `capture_prompt` (`src/dev/dev.zig`) and the daemon's dynamic absolute-path variant — 164 absolute-path examples were found in the existing exports — and all 547 `<prompt>` invocations in `fixtures/index.json` resolve to one of those two. Only that capture instruction is filtered. Repeated short tasks such as `Reply with the single word: PONG` and `Translate humanist to/from Indonesian` are **not** filtered — they are ordinary conversations and go through consolidation instead.

Remote harnesses (Kagi) cache raw API responses under `<output>/cache/kagi/`. Branch message pages are keyed by branch id, revision time and message count, so revived or extended threads refetch automatically; attachments are keyed by URL. If a request fails, the newest cached raw response for that endpoint is reused instead of dropping the data. The cache is preserved by `--purge`.

## Output

```
~/Documents/AI/
├── opencode/
│   ├── 2026-08-13 20-11 - 7858be5c - Fixtures to JSON top weekly programming models.md
│   ├── json/
│   │   └── 2026-08-13 20-11 - 7858be5c - Fixtures to JSON top weekly programming models.json
│   └── attachments/          (created only when there are attachments)
│       └── 2026-08-13 20-11 - 7858be5c - Screenshot.png
├── cline/
├── kilo/
└── ...
```

The timestamp is the session's own creation time in UTC, rendered as `yyyy-mm-dd hh-mm`. The short id is a stable hash of the source session id. Titles keep human-readable spaces and punctuation; filesystem-hostile characters become spaces. When a source title is missing, truncated, or generic, the tool asks on-device `fm respond` for a single-line APFS-safe summary of the opening prompt; results are cached in `archives/.title-cache.tsv`.

Archives are relocated by the maintainer into `archives/<timestamp> - <harness>/` before the final export run; the CLI only reads the paths it is given and never copies from the original download locations.

The `.md` file holds only `### Prompt` and `### Answer` turns. Each answer heading carries the model that produced it when known, as `### Answer — <provider>/<model>` (or just the model id when no provider is recorded). This keeps deliberate same-prompt/different-model comparisons readable instead of collapsing them into one transcript. The `.json` file holds all metadata: session id, title, harness, provider, model, working directory, source store, timestamp, attachment records, and every message with its role and time. Kagi upload URLs are downloaded with the session cookie and written into the harness's `attachments/` directory; no other harness currently exposes attachment files.

## Supported stores

| Family | Harnesses |
| --- | --- |
| SQLite session stores | opencode (v2 + legacy parts), kilo, anythingllm, goose, crush (project-local), copilot (VS Code chat) |
| JSON session directories | cline, codewhale |
| JSONL transcript trees | codex, dsh (zstd-compressed), zcode, pi, qwen, reasonix, claude, autoclaw |

Adding a store is a table row in `src/lib/readers.zig`. Message-shape differences are handled in `src/lib/normalize.zig`, which folds strings, block arrays, nested `message`/`payload`/`request` objects, and `user`/`assistant`/`agent` role spellings into one shape.

Not covered yet: Claude Desktop's IndexedDB LevelDB store, Codex's secondary SQLite mirrors (the JSONL rollouts are used instead), Copilot CLI's empty-window JSONL, and harnesses with no local transcript such as Zed on this machine.

## Safety

## Archives and duplicates

External archives (TypingMind JSON, Claude conversation exports, ChatGPT/OpenAI zip exports) are ingested with `--archive`; zip files are read in place, only their extracted contents are catalogued under `<output>/archives/<timestamp> - <harness>/`, and the transport zips are then moved to the Trash. The CLI never relocates source archives: relocation is done by the maintainer before invoking `--import-archives`.

Within a harness, exact copies collapse and an older transcript that is contained in a longer one is merged away — including repeated short tasks that picked up a fresh session id but kept the same title and opening prompt. Copies with identical prompts but different answers are treated as model comparisons and kept without a conflict entry; other divergent copies are kept and listed in `<output>/conflicts.json`. Dedupe runs on every invocation, not only when archives are supplied. Between harnesses, copies are **never** merged — `<output>/duplicates.json` records each pair as `exact`, `extended`, or `variant`, with the harnesses, titles, ids, and how many extra messages one side has. It also records a `confidence` and a `reason`: the known TypingMind → AnythingLLM import path is high confidence, while other pairs only get a low-confidence ordering by timestamp. Content alone cannot prove which side is the original.

## Safety

Harness stores are opened read-only. The only writes are under the chosen output directory, and generated files there are disposable. Harness data is never deleted, moved, or rewritten.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
