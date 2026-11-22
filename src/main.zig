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

pub const usage =
    \\ai-export-sync — export harness chats to Markdown and JSON files
    \\
    \\usage:
    \\  ai-export-sync [options]
    \\
    \\options:
    \\  --output=<dir>     output directory (default: ~/Documents/AI)
    \\  --harness=<id>     export only one harness (opencode, kilo, cline, dsh, zcode, ...)
    \\  --dry-run          discover and report, write nothing
    \\  --version          print the version
    \\  --help             show this help
    \\
    \\files per session:
    \\  <stamp>-<harness>-<title>.md    prompts and answers only
    \\  <stamp>-<harness>-<title>.json  all metadata and messages
    \\  attachments/<stamp>-<harness>-<attachment>.<ext>
    \\
;

fn writeOut(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn writeErr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
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
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
        } else if (std.mem.startsWith(u8, arg, "--harness=")) {
            only = arg["--harness=".len..];
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

    var writer = if (dry_run) null else try render.Writer.init(a, io, output);
    for (sessions.items) |session| {
        if (writer) |*w| {
            _ = try w.writeSession(session);
        }
    }
    if (writer) |*w| try w.saveManifest();

    const summary = try std.fmt.allocPrint(a,
        "scanned: {d} sessions · exported: {d} · unchanged: {d} · skipped: {d} · failed: {d} · attachments: {d}\noutput: {s}\n",
        .{ stats.scanned, if (writer) |w| w.written else 0, if (writer) |w| w.skipped else 0, stats.skipped, stats.failed, if (writer) |w| w.attachment_count else 0, output },
    );
    writeOut(io, summary);
    return 0;
}
