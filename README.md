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

Options: `--output=<dir>` changes the destination; `--harness=<id>` limits the run to one harness; `--dry-run` reports without writing; `--help` prints all options.

Every run is a full regeneration. Previous exports under the chosen output directory are wiped first, so a format change never leaves two generations of files side by side.

## Output

```
~/Documents/AI/
├── opencode/
│   ├── 2026-08-13 20-11 - 7858be5c - Fixtures to JSON top weekly programming models.md
│   ├── 2026-08-13 20-11 - 7858be5c - Fixtures to JSON top weekly programming models.json
│   └── attachments/
│       └── 2026-08-13 20-11 - 7858be5c - Screenshot.png
├── cline/
├── kilo/
└── ...
```

The timestamp is the session's own creation time in UTC, rendered as `yyyy-mm-dd hh-mm`. The short id is a stable hash of the source session id. Titles keep human-readable spaces and punctuation; filesystem-hostile characters become spaces.

The `.md` file holds only `### Prompt` and `### Answer` turns. The `.json` file holds all metadata: session id, title, harness, provider, model, working directory, source store, timestamp, attachment records, and every message with its role and time.

## Supported stores

| Family | Harnesses |
| --- | --- |
| SQLite session stores | opencode (v2 + legacy parts), kilo, anythingllm, goose, crush (project-local), copilot (VS Code chat) |
| JSON session directories | cline, codewhale |
| JSONL transcript trees | codex, dsh (zstd-compressed), zcode, pi, qwen, reasonix, claude, autoclaw |

Adding a store is a table row in `src/lib/readers.zig`. Message-shape differences are handled in `src/lib/normalize.zig`, which folds strings, block arrays, nested `message`/`payload`/`request` objects, and `user`/`assistant`/`agent` role spellings into one shape.

Not covered yet: Claude Desktop's IndexedDB LevelDB store, Codex's secondary SQLite mirrors (the JSONL rollouts are used instead), Copilot CLI's empty-window JSONL, and harnesses with no local transcript such as Zed on this machine.

## Safety

Harness stores are opened read-only. The only writes are under the chosen output directory, and generated files there are disposable. Harness data is never deleted, moved, or rewritten.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
