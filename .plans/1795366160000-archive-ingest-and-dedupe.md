# Ingest external chat archives, dedupe, and catalogue exports

Assisted-by: OpenCode · Hy4 Flash <opencode-opencodego-hy4flash@local>

> Prompts: [1795366160000-archive-ingest-and-dedupe.prompts.md](1795366160000-archive-ingest-and-dedupe.prompts.md)

Status: implementation-ready

## Context

The Bevry `ai-sync` command never used a TypingMind database. Its help, types, and git history only reference a **TypingMind JSON export** supplied with `--import-typingmind-json-export=<path>`; the backups it wrote were `anythingllm.db.backup.*.db` in `~/.local/state/dorothy/ai-sync/`. No TypingMind app-support directory exists on this machine. The archives the user named are the actual TypingMind data.

Archives supplied:

| Path | Shape |
| --- | --- |
| `~/Downloads/typingmind-export 2.json`, `typingmind-export.json`, `~/Downloads/20261123_001528_typingmind_export/data.json`, `/Volumes/Scratchpad/Downloads/typingmind-chats.json`, `/Volumes/Scratchpad/Downloads/ai-exports/typingmind.json` | TypingMind `{ data: { chats: [...] } }`, 10–166 chats each |
| `/Volumes/Scratchpad/Downloads/ai-exports/claude-data-…/conversations.json` | Claude list of 175 conversations with `chat_messages` |
| `/Volumes/Scratchpad/Downloads/ai-exports/<hash>-….zip` | ChatGPT/OpenAI export containing `conversations-000.json`, `conversations-001.json`, `chat.html`, and `dalle-generations/` |
| `~/Downloads/claude-memory-2026-11-23/` plus its manifest | Claude memory markdown, not chats — catalogue only |

## Decision

| Option | Verdict |
| --- | --- |
| Extend the existing harness readers with one table row per archive | Rejected — archives are user-supplied paths with three different JSON shapes and a zip |
| Add a dedicated `--archive=<path>` ingest path with shape detection, then feed the same `Session` model | Chosen — keeps live-store discovery untouched and reuses rendering |
| Import TypingMind into AnythingLLM like the old command | Rejected — user explicitly removed harness-to-harness import |

## Change

### Ingest

- `--archive=<path>` may be repeated; directories are walked for `.json`, zip files are read through `unzip -Z1` / `unzip -p` (read-only, no extraction into harness dirs).
- Shape detection: TypingMind `data.chats` with `chatID`/`messages`; Claude list items with `chat_messages`; ChatGPT list items with `mapping`/`create_time`. Generic `metadata.json` files are skipped.
- Archives become sessions with `harness` = `typingmind`, `claude`, or `chatgpt`, and keep their source path in metadata.

### Dedupe and merge

- Within a harness: group by session id, then by hash of the first message when no id exists. Identical message sequences collapse to one copy (the one with the richest metadata survives). If one sequence contains the other in order, the extended copy survives and the shorter one is merged away. If neither contains the other, both survive and the pair is written to `~/Documents/AI/conflicts.json` with ids, titles, and counts.
- Between harnesses: compare message-sequence hashes. Write `~/Documents/AI/duplicates.json` listing every cross-harness pair with `exact` or `extended`, plus which side has additional messages. Cross-harness matches are never merged — they are only reported, because a chat exported from one harness into another is evidence of provenance, not of a single session.

### Catalogue

- Original archives are copied (never moved) into `~/Documents/AI/exports/<timestamp> - <harness>/`, preserving internal structure. Generic names (`data.json`, `conversations.json`) get a `<timestamp> - <harness> - ` prefix. Multi-file exports keep their files together.

### "Bad data" filter

Sessions with no user/assistant messages, control-only messages, or unparseable JSON are skipped and counted. Nothing is deleted from the source archives.

## Verification

- Restore a temp output directory, run with all named archives, and check the per-harness counts and the two JSON reports.
- Re-run to confirm the full regeneration leaves one generation of files.
- Confirm source archives are byte-identical before and after (copy only).
- Keep 9 pre-existing skipped live sessions stable.
