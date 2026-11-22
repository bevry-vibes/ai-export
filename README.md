# ai-export-sync

Export AI harness chats to plain Markdown and JSON files on disk — one file pair per session, with attachments copied alongside.

The tool reads harness session stores read-only. It never writes back to a harness, never imports conversations into another harness, and never needs an API key.

## Why

The old Dorothy `ai-sync` command imported TypingMind JSON exports into AnythingLLM's SQLite database. That direction is gone. This project only exports harness chats to files, so the result is portable, greppable, and independent of any vendor's import format.

Harness discovery follows [agent-detect](https://github.com/bevry-vibes/agent-detect)'s session-store paths and Zig conventions. `agent-detect` remains the source of truth for which harnesses exist and where they keep their sessions; this project adds the transcript-reading and file-rendering half.

## Requirements

- Zig 0.17.0 (installed into the gitignored `vendor/zig/` on first `./scripts/zig` call)
- `sqlite3` on PATH for database-backed harnesses

## Usage

```sh
./scripts/zig build                       # build into zig-out/bin
./zig-out/bin/ai-export-sync --dry-run    # discover sessions, write nothing
./zig-out/bin/ai-export-sync              # export everything into ~/Documents/AI
./zig-out/bin/ai-export-sync --output=~/Documents/AI --harness=opencode
./zig-out/bin/ai-export-sync --version
```

Options: `--output=<dir>` changes the destination; `--harness=<id>` limits the run to one harness; `--dry-run` reports without writing; `--help` prints all options.

A run is incremental. A manifest at `<output>/.ai-export-sync-manifest.tsv` records a hash of each session's messages, so unchanged sessions are skipped. When a session changes, its previous output pair is removed before the new pair is written.

## Output

For each session the tool writes:

```
~/Documents/AI/20261122T101530Z-opencode-fix-the-build.md
~/Documents/AI/20261122T101530Z-opencode-fix-the-build.json
~/Documents/AI/attachments/20261122T101530Z-opencode-screenshot.png
```

The `.md` file holds only the prompt and answer turns. The `.json` file holds all metadata: session id, title, harness, provider, model, working directory, source store, timestamp, attachment records, and every message with its role and time. Attachment names use `<stamp>-<harness>-<attachment title>.<original extension>`.

## Supported stores

| Family | Harnesses |
| --- | --- |
| SQLite session stores | opencode, kilo |
| JSON session directories | cline, codewhale |
| JSONL transcript trees | dsh, zcode, autoclaw, codex, claude |

Adding a store is a table row in `src/lib/readers.zig`. Message-shape differences are handled in `src/lib/normalize.zig`, which folds strings, block arrays, nested `message`/`payload` objects, and `user`/`assistant`/`agent` role spellings into one shape.

Not covered yet: Zed's zstd-compressed thread blobs, Crush and Copilot CLI databases whose schemas differ per version, and harnesses that keep no local transcript. Patches welcome.

## Safety

Harness stores are opened read-only. The only writes are under the chosen output directory. Generated Markdown and JSON files are disposable; harness data is never deleted, moved, or rewritten.

<!-- LICENSE/ -->

## License

Unless stated otherwise all works are:

- Copyright &copy; [Benjamin Lupton](https://balupton.com)

and licensed under:

- [Reciprocal Public License 1.5](http://spdx.org/licenses/RPL-1.5.html)

<!-- /LICENSE -->
