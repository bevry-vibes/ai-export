# AGENTS.md

This project conforms to Bevry's skills.
Reference their remote URLs only — do not pull their contents into this file.
When a referenced skill applies with this project's tweaks, the local `<name>.md` file at this repo root references the remote URL and lists the tweaks underneath;
this process is documented in the upstream repo's [local tweaks pattern](https://github.com/bevry-vibes/skills#local-tweaks-pattern).

- https://github.com/bevry-vibes/skills/blob/main/policy.md — **applies.** Identify the agent with [agent-detect](https://github.com/bevry-vibes/agent-detect) and confirm reciprocity before working on this project.
- https://github.com/bevry-vibes/skills/blob/main/secrets.md — **applies.** Secrets come only from their documented locations; never probe for them, print them, or commit them.
- https://github.com/bevry-vibes/skills/blob/main/author.md — **applies.** Authorship, trailers, and signing.
- https://github.com/bevry-vibes/skills/blob/main/commits.md — **applies.** Conventional Commits with generated trailers.
- https://github.com/bevry-vibes/skills/blob/main/conventions.md — **applies.** The bevry/base config files stay verbatim above their CUSTOM segments.
- https://github.com/bevry-vibes/skills/blob/main/plans.md — **applies.** Plans and their prompt companions live in `.plans/`.
- https://github.com/bevry-vibes/skills/blob/main/zig.md — **applies.** Zig API notes and gotchas.
- https://github.com/bevry-vibes/skills/blob/main/minimax.md — **applies** when the running agent is a MiniMax M3 model.
- https://github.com/bevry-vibes/skills/blob/main/powershell.md — **does not apply.** This project ships a Zig binary and no PowerShell scripts.

## project rules

Build with `./scripts/zig build`, test with `./scripts/zig build test`, and cross-compile with `./scripts/zig build dist` once the pinned compiler wrapper is added. The compiler pin lives in `build.zig.zon`.

Session-store paths and message shapes come from [agent-detect](https://github.com/bevry-vibes/agent-detect). This project reads those stores read-only. Never create, modify, or overwrite a harness's config or auth files, and never set API keys.

The old Dorothy `ai-sync` command informs *what* this tool does (export conversations), not *how* it is built. Do not copy, port, or vendor that command's TypingMind-to-AnythingLLM importer. This tool only exports harness chats to files; it never imports into another harness.

Output files live under `~/Documents/AI` by default. Generated files are disposable: never delete user data from a harness store, and never write into a harness store.
