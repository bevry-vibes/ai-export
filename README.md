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

Options: `--output=<dir>` changes the destination; `--harness=<id>` limits the run to one harness; `--archive=<path>` ingests an external export (repeatable); `--kagi` fetches Kagi Assistant chats using the `KAGI_SESSION` cookie from the environment; `--kagi-share=<id>` fetches one public Kagi share; `--include-noise` keeps agent-detect fixtures-capture sessions; `--dry-run` reports without writing; `--help` prints all options.

Agent-detect noise is filtered out by default. The capture phrase `in the current working directory and report the result` appears in both the static `capture_prompt` (`src/dev/dev.zig`) and the daemon's dynamic absolute-path variant — 164 absolute-path examples were found in the existing exports — and all 547 `<prompt>` invocations in `fixtures/index.json` resolve to one of those two. Cline team sub-sessions spawned by that harness (`team-*` id plus a throwaway `/T/tmp` working directory), plus the repeated fixture prompts (`Reply with the single word: PONG`, `Reply with exactly: RXOK`, `Translate humanist to/from Indonesian`), are filtered too. These sub-sessions have no parent-session id in the store, so they cannot be reliably merged into a parent chat; dropping them is the only coherent option.

Every run is a full regeneration. Previous exports under the chosen output directory are wiped first, so a format change never leaves two generations of files side by side.

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

The timestamp is the session's own creation time in UTC, rendered as `yyyy-mm-dd hh-mm`. The short id is a stable hash of the source session id. Titles keep human-readable spaces and punctuation; filesystem-hostile characters become spaces.

The `.md` file holds only `### Prompt` and `### Answer` turns. The `.json` file holds all metadata: session id, title, harness, provider, model, working directory, source store, timestamp, attachment records, and every message with its role and time. Kagi upload URLs are downloaded with the session cookie and written into the harness's `attachments/` directory; no other harness currently exposes attachment files.

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

External archives (TypingMind JSON, Claude conversation exports, ChatGPT/OpenAI zip exports) are ingested with `--archive`; zip files are read in place, only their extracted contents are catalogued under `<output>/exports/<timestamp> - <harness>/`, and the transport zips are then moved to the Trash. Source JSON archives are copied, never moved or deleted.

Within a harness, exact copies collapse and an older transcript that is contained in a longer one is merged away; conflicting copies are listed in `<output>/conflicts.json`. Between harnesses, copies are **never** merged — `<output>/duplicates.json` records each pair as `exact`, `extended`, or `variant`, with the harnesses, titles, ids, and how many extra messages one side has. It also records a `confidence` and a `reason`: the known TypingMind → AnythingLLM import path is high confidence, while other pairs only get a low-confidence ordering by timestamp. Content alone cannot prove which side is the original.

## Safety

Harness stores are opened read-only. The only writes are under the chosen output directory, and generated files there are disposable. Harness data is never deleted, moved, or rewritten.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
