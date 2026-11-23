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
    \\  --import-archives   also import every archive under <output>/archives
    \\  --purge             delete harness directories and reports before writing
    \\  --no-title-generation  skip fm respond title summaries
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

var log_output: ?[]const u8 = null;

fn appendLog(io: std.Io, name: []const u8, text: []const u8) void {
    const root = log_output orelse return;
    if (text.len == 0) return;
    const a = std.heap.page_allocator;
    const path = std.fs.path.join(a, &.{ root, name }) catch return;
    var bytes: []const u8 = text;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(@as(u64, 16 << 20)))) |old| {
        bytes = std.mem.concat(a, u8, &.{ old, text }) catch text;
    } else |_| {}
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {};
}

fn writeOut(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    appendLog(io, "state.stdout.log", text);
}

fn writeErr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    appendLog(io, "state.stderr.log", text);
}

const progress_mod = @import("lib/progress.zig");
const Progress = progress_mod.Tracker;

fn capture(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .ignore }) catch return error.TitleGeneratorUnavailable;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(a, chunk[0..n]);
    }
    const term = child.wait(io) catch return error.TitleGeneratorUnavailable;
    switch (term) {
        .exited => |code| if (code != 0) return error.TitleGeneratorUnavailable,
        else => return error.TitleGeneratorUnavailable,
    }
    return out.toOwnedSlice(a);
}

fn poorTitle(title: []const u8) bool {
    if (title.len > 55) return true;
    if (std.mem.indexOf(u8, title, "...") != null or std.mem.indexOf(u8, title, "…") != null) return true;
    if (std.mem.startsWith(u8, title, "New session -")) return true;
    return false;
}

fn generateTitle(a: std.mem.Allocator, io: std.Io, cache: *std.StringHashMap([]const u8), budget: *usize, session: model.Session) !?[]const u8 {
    if (!poorTitle(session.title)) return null;
    if (cache.get(session.id)) |cached| return cached;
    const initial = if (session.messages.len > 0) session.messages[0].content else "";
    if (initial.len == 0) return null;
    // Generic harness-generated titles can be replaced from the opening line
    // without spending an fm call.
    if (std.mem.startsWith(u8, session.title, "New session -") or std.mem.eql(u8, session.title, "Untitled session")) {
        const line_end = std.mem.indexOfScalar(u8, initial, '\n') orelse initial.len;
        const line = std.mem.trim(u8, initial[0..line_end], " \t#*-_\">");
        if (line.len > 0) {
            const title = try model.humanTitle(a, line[0..@min(line.len, 70)]);
            try cache.put(try a.dupe(u8, session.id), title);
            return title;
        }
    }
    if (budget.* == 0) {
        const line_end = std.mem.indexOfScalar(u8, initial, '\n') orelse initial.len;
        const title = try model.humanTitle(a, initial[0..@min(line_end, 70)]);
        try cache.put(try a.dupe(u8, session.id), title);
        return title;
    }
    budget.* -= 1;
    const snippet = initial[0..@min(initial.len, 600)];
    const prompt = try std.fmt.allocPrint(a, "Summarise the following into a single-line title, compatible with APFS filesystem:\n\n{s}", .{snippet});
    const raw = capture(a, io, &.{ "fm", "respond", "--no-stream", "--greedy", prompt }) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'`");
    if (trimmed.len == 0) return null;
    const title = try model.humanTitle(a, trimmed);
    if (title.len == 0) return null;
    try cache.put(try a.dupe(u8, session.id), title);
    return title;
}

fn isAgentDetectNoise(a: std.mem.Allocator, session: model.Session) bool {
    for (session.messages) |message| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        const lowered = std.ascii.allocLowerString(a, message.content) catch continue;
        return std.mem.indexOf(u8, lowered, "in the current working directory and report the result") != null and
            std.mem.indexOf(u8, lowered, "fixtures capture") != null;
    }
    return false;
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
    var import_archives = false;
    var title_generation = true;
    var title_budget: usize = 100;
    var include_noise = false;
    var purge = false;
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
        } else if (std.mem.eql(u8, arg, "--import-archives")) {
            import_archives = true;
        } else if (std.mem.eql(u8, arg, "--no-title-generation")) {
            title_generation = false;
        } else if (std.mem.startsWith(u8, arg, "--title-budget=")) {
            title_budget = std.fmt.parseInt(usize, arg["--title-budget=".len..], 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--purge")) {
            purge = true;
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
    try std.Io.Dir.cwd().createDirPath(io, output);
    log_output = output;
    for ([_][]const u8{ "state.stdout.log", "state.stderr.log" }) |name| {
        const path = try std.fs.path.join(a, &.{ output, name });
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    var progress = Progress{ .a = a, .io = io, .output = output, .started_ns = Progress.now(io), .last_ns = Progress.now(io) };
    try progress.write();
    const progress_thread = try progress.start();
    defer {
        progress.stop();
        progress_thread.join();
    }

    var sessions: std.ArrayList(model.Session) = .empty;
    var stats = readers.Stats{};
    progress.phase = "file-stores";
    try progress.write();
    try readers.collectFileSessions(a, io, home, &sessions, &stats, only, &progress);
    progress.phase = "sql-stores";
    try progress.write();
    readers.collectSqlSessions(a, io, home, &sessions, &stats, only, &progress) catch |err| {
        if (err == error.SqliteUnavailable) {
            writeErr(io, "sqlite3 is not installed — database-backed harnesses were skipped\n");
        } else {
            return err;
        }
    };

    progress.phase = "kagi";
    try progress.write();
    const cache_root = try std.fs.path.join(a, &.{ output, "cache" });
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    if (want_kagi or (import_archives and env.get("KAGI_SESSION") != null)) {
        kagi.collectKagi(a, io, env, &sessions, &stats, &progress, cache_root) catch |err| {
            writeErr(io, "kagi fetch failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }
    for (share_ids.items) |id| {
        kagi.collectShare(a, io, id, &sessions, &stats, cache_root) catch |err| {
            writeErr(io, "kagi share failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }

    progress.phase = "archives";
    try progress.write();
    if (import_archives) {
        const archives_root = try std.fs.path.join(a, &.{ output, "archives" });
        archives.collectFromArchives(a, io, archives_root, &sessions, &stats) catch |err| {
            writeErr(io, "exports import failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }

    progress.phase = "discovered";
    progress.total = sessions.items.len;
    progress.processed = sessions.items.len;
    try progress.write();

    progress.phase = "filtering";
    try progress.write();
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
        const catalog_root = try std.fs.path.join(a, &.{ output, "archives" });
        if (!dry_run) try std.Io.Dir.cwd().createDirPath(io, catalog_root);
        archives.collectArchives(a, io, archive_paths.items, &sessions, &stats, catalog_root, !dry_run) catch |err| {
            writeErr(io, "archive ingest failed: ");
            writeErr(io, @errorName(err));
            writeErr(io, "\n");
        };
    }
    report = try dedupe.process(a, &sessions);
    progress.phase = "consolidated";
    progress.total = sessions.items.len;
    progress.processed = sessions.items.len;
    progress.noise_filtered = noise_filtered;
    progress.collapsed = report.collapsed;
    progress.merged = report.merged;
    progress.duplicates = report.duplicates.len;
    progress.conflicts = report.conflicts.len;
    try progress.write();

    const archives_root = try std.fs.path.join(a, &.{ output, "archives" });
    if (!dry_run) try std.Io.Dir.cwd().createDirPath(io, archives_root);
    var title_cache = std.StringHashMap([]const u8).init(a);
    const cache_path = try std.fs.path.join(a, &.{ archives_root, ".title-cache.tsv" });
    if (std.Io.Dir.cwd().readFileAlloc(io, cache_path, a, @enumFromInt(@as(u64, 4 << 20)))) |bytes| {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = fields.next() orelse continue;
            const title = fields.next() orelse continue;
            try title_cache.put(try a.dupe(u8, id), try a.dupe(u8, title));
        }
    } else |_| {}
    var titled: usize = 0;
    var budget = title_budget;
    if (title_generation) {
        progress.phase = "titles";
        for (sessions.items) |*session| {
            if (try generateTitle(a, io, &title_cache, &budget, session.*)) |title| {
                session.title = title;
                titled += 1;
            }
            progress.titled = titled;
            try progress.maybe();
        }
    }
    if (!dry_run) {
        var cache_out: std.ArrayList(u8) = .empty;
        var cit = title_cache.iterator();
        while (cit.next()) |entry| {
            const line = try std.fmt.allocPrint(a, "{s}\t{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try cache_out.appendSlice(a, line);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_path, .data = cache_out.items });
    }

    // Known cross-harness copies: only byte-identical (normalised) duplicates
    // are quarantined. Variants and extended copies stay in their harness
    // directory with a link back to the original transcript.
    var quarantined: usize = 0;
    var linked: usize = 0;
    for (report.duplicates) |dup| {
        if (!std.mem.eql(u8, dup.confidence, "high")) continue;
        const copy_id = if (std.mem.eql(u8, dup.copy_harness, dup.a_harness)) dup.a_id else dup.b_id;
        const original_id = if (std.mem.eql(u8, dup.copy_harness, dup.a_harness)) dup.b_id else dup.a_id;
        var copy: ?*model.Session = null;
        var original: ?*model.Session = null;
        for (sessions.items) |*session| {
            if (copy == null and std.mem.eql(u8, session.harness, dup.copy_harness) and std.mem.eql(u8, session.id, copy_id)) copy = session;
            if (original == null and std.mem.eql(u8, session.harness, dup.original_harness) and std.mem.eql(u8, session.id, original_id)) original = session;
        }
        const c = copy orelse continue;
        const o = original orelse continue;
        if (std.mem.eql(u8, dup.kind, "exact")) {
            c.quarantined = true;
            quarantined += 1;
        } else {
            const stem = try render.sessionStem(a, o.*);
            c.link_to = try std.fmt.allocPrint(a, "[{s}](../{s}/{s}.md)", .{ o.title, o.harness, stem });
            linked += 1;
        }
    }

    var writer = if (dry_run) null else try render.Writer.init(a, io, output, purge);
    progress.phase = "writing";
    progress.total = sessions.items.len;
    progress.processed = 0;
    for (sessions.items) |session| {
        if (writer) |*w| {
            try w.writeSession(session);
            progress.exported = w.written;
            progress.attachments = w.attachment_count;
        }
        progress.processed += 1;
        try progress.maybe();
    }
    if (writer != null) try dedupe.writeReports(a, io, output, report);
    progress.phase = "done";
    progress.processed = sessions.items.len;
    try progress.write();

    const summary = try std.fmt.allocPrint(a,
        "scanned: {d} sessions · noise filtered: {d} · titled: {d} · quarantined: {d} · linked: {d} · exported: {d} · skipped: {d} · failed: {d} · attachments: {d} · collapsed: {d} · merged: {d} · cross-harness duplicates: {d} · conflicts: {d}\noutput: {s}\n",
        .{ stats.scanned, noise_filtered, titled, quarantined, linked, if (writer) |w| w.written else 0, stats.skipped, stats.failed, if (writer) |w| w.attachment_count else 0, report.collapsed, report.merged, report.duplicates.len, report.conflicts.len, output },
    );
    writeOut(io, summary);
    return 0;
}
