// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");
const build_options = @import("build_options");
const readers = @import("lib/readers.zig");
const render = @import("lib/render.zig");
const model = @import("lib/model.zig");
const normalize = @import("lib/normalize.zig");
const archives = @import("lib/archives.zig");
const dedupe = @import("lib/dedupe.zig");
const kagi = @import("lib/kagi.zig");

pub const usage =
    \\ai-export — export harness chats to Markdown and JSON files
    \\
    \\usage:
    \\  ai-export [options]
    \\
    \\options:
    \\  --output=<dir>     output directory (default: ~/Documents/AI)
    \\  --harness=<id>     export only one harness (opencode, kilo, cline, dsh, zcode, ...)
    \\  --archive=<path>   ingest an external export (repeatable)
    \\  --kagi             fetch Kagi Assistant chats (needs KAGI_SESSION)
    \\  --kagi-share=<id>  fetch one public Kagi share
    \\  --include-noise    keep agent-detect fixtures-capture sessions
    \\  --dry-run          discover and report, write nothing
    \\  --version          print the version
    \\  --help             show this help
    \\
    \\files per session:
    \\  <harness>/yyyy-mm-dd hh-mm - <session-id> - <title>.md
    \\  <harness>/yyyy-mm-dd hh-mm - <session-id> - <title>.json
    \\  <harness>/attachments/yyyy-mm-dd hh-mm - <session-id> - <attachment>.<ext>
    \\
;

fn writeOut(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn writeErr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

fn isAgentDetectNoise(a: std.mem.Allocator, session: model.Session) bool {
    const team_session = std.mem.startsWith(u8, session.team, "team-");
    const fixture_prompts = [_][]const u8{
        "in the current working directory and report the result",
        "reply with the single word: pong",
        "reply with exactly: rxok",
        "translate humanist to indonesian",
        "translate humanist into indonesian",
    };
    for (session.messages) |message| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        const lowered = std.ascii.allocLowerString(a, message.content) catch continue;
        for (fixture_prompts) |needle| {
            if (std.mem.indexOf(u8, lowered, needle) != null) return true;
        }
        if (team_session and std.mem.indexOf(u8, lowered, "skill document (follow it in full)") != null) return true;
        break;
    }
    // Cline team sub-sessions spawned by agent-detect's fixture harness all
    // carry a unique `team-*` id and a throwaway temp working directory.
    return team_session and std.mem.indexOf(u8, session.cwd, "/T/tmp") != null;
}

pub fn main(init: std.process.Init) u8 {
    return mainInner(init) catch |err| {
        writeErr(init.io, @errorName(err));
        writeErr(init.io, "\n");
        return 1;
    };
}

fn mainInner(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var output: []const u8 = "";
    var only: []const u8 = "";
    var dry_run = false;
    var want_kagi = false;
    var include_noise = false;
    var archive_paths: std.ArrayList([]const u8) = .empty;
    var share_ids: std.ArrayList([]const u8) = .empty;
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, a) catch return 1;
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeOut(io, usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            writeOut(io, build_options.version);
            writeOut(io, "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--kagi")) {
            want_kagi = true;
        } else if (std.mem.startsWith(u8, arg, "--kagi-share=")) {
            try share_ids.append(a, arg["--kagi-share=".len..]);
        } else if (std.mem.eql(u8, arg, "--include-noise")) {
            include_noise = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
        } else if (std.mem.startsWith(u8, arg, "--harness=")) {
            only = arg["--harness=".len..];
        } else if (std.mem.startsWith(u8, arg, "--archive=")) {
            try archive_paths.append(a, arg["--archive=".len..]);
        } else {
            writeErr(io, "unrecognised argument: ");
            writeErr(io, arg);
            writeErr(io, "\n");
            writeOut(io, usage);
            return 2;
        }
    }

    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse {
        writeErr(io, "HOME is not set\n");
        return 1;
    };
    if (output.len == 0) output = try std.fs.path.join(a, &.{ home, "Documents/AI" });

    var sessions: std.ArrayList(model.Session) = .empty;
    var stats = readers.Stats{};
    try readers.collectFileSessions(a, io, home, &sessions, &stats, only);
    readers.collectSqlSessions(a, io, home, &sessions, &stats, only) catch |err| {
        if (err == error.SqliteUnavailable) {
            writeErr(io, "sqlite3 is not installed — database-backed harnesses were skipped\n");
        } else {
            return err;
        }
    };

    if (want_kagi) {
        kagi.collectKagi(a, io, env, &sessions, &stats) catch |err| {
            writeErr(io, "kagi fetch failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }
    for (share_ids.items) |id| {
        kagi.collectShare(a, io, id, &sessions, &stats) catch |err| {
            writeErr(io, "kagi share failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }

    var noise_filtered: usize = 0;
    if (!include_noise) {
        var i: usize = sessions.items.len;
        while (i > 0) {
            i -= 1;
            if (isAgentDetectNoise(a, sessions.items[i])) {
                _ = sessions.orderedRemove(i);
                noise_filtered += 1;
            }
        }
    }

    var report = dedupe.Result{};
    if (archive_paths.items.len > 0 or want_kagi or share_ids.items.len > 0) {
        const catalog_root = try std.fs.path.join(a, &.{ output, "exports" });
        if (!dry_run) try std.Io.Dir.cwd().createDirPath(io, catalog_root);
        archives.collectArchives(a, io, archive_paths.items, &sessions, &stats, catalog_root, !dry_run) catch |err| {
            writeErr(io, "archive ingest failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
        report = try dedupe.process(a, &sessions);
    }

    var writer = if (dry_run) null else try render.Writer.init(a, io, output);
    for (sessions.items) |session| {
        if (writer) |*w| {
            try w.writeSession(session);
        }
    }
    if (writer != null) try dedupe.writeReports(a, io, output, report);

    const summary = try std.fmt.allocPrint(a,
        "scanned: {d} sessions · noise filtered: {d} · exported: {d} · skipped: {d} · failed: {d} · attachments: {d} · collapsed: {d} · merged: {d} · cross-harness duplicates: {d} · conflicts: {d}\noutput: {s}\n",
        .{ stats.scanned, noise_filtered, if (writer) |w| w.written else 0, stats.skipped, stats.failed, if (writer) |w| w.attachment_count else 0, report.collapsed, report.merged, report.duplicates.len, report.conflicts.len, output },
    );
    writeOut(io, summary);
    return 0;
}
