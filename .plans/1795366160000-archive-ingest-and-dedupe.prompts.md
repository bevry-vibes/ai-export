# Ingest external chat archives, dedupe, and catalogue exports — prompts

Plan: [1795366160000-archive-ingest-and-dedupe.md](1795366160000-archive-ingest-and-dedupe.md)

## Session metadata

- Harness: OpenCode CLI
- Provider: opencode-go
- Model: hy4-flash-free (`hy4-flash`)
- Reciprocity: `is reciprocal`, exit 0
- Timestamps: not observable in this harness; plan name uses the current epoch

## Prompt 1

```
There should have been a typingmind database file stored somewhere, which governed the original dorothy ai-sync - is it still there, is there a backup there - don't query my whole hard drive, just look for references. As per other backups, I did find these old arcchives:

/Users/balupton/Downloads/typingmind-export\ 2.json
/Users/balupton/Downloads/typingmind-export.json
/Volumes/Scratchpad/Downloads/typingmind-chats.json

and this new archive that I just exported from typindming cloud
/Users/balupton/Downloads/20261123_001528_typingmind_export

and these historical exports from several ai chats:
/Volumes/Scratchpad/Downloads/ai-exports

run them all through our exported, deduping, and cleaning up - filtering out bad data, merging good data, etc - raising conflicting data
for dedupe, just dedupe within a harness, but note in a ~/Documents/AI/duplicates.json file when there appears to be duplicates between harnesses (say a chat was exporteed from one to another), and whether the duplication is exact or extended (additional messages were added into the duplicate/export/target).

I'm doing fresh exports of anthropic/claude and chatgpt/openai, will let you know when they are done.

anthropoic is done:
/Users/balupton/Downloads/claude-memory-2026-11-23
/Users/balupton/Downloads/manifest-e4c65f42-b475-470b-8d6a-d8086d3f5c20-1795364636-8fb0d979-2026-11-22-16-24-31.json

you can also relocate and catalog these exports, putting them in `~/Documents/AI/exports/timestamp - harness/` with helpful names if the name was generic
```
