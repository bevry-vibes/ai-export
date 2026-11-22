// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");
const model = @import("model.zig");
const normalize = @import("normalize.zig");

const Session = model.Session;
const Message = model.Message;
const Attachment = model.Attachment;

pub const FileSpec = struct {
    harness: []const u8,
    root: []const u8, // relative to HOME
    suffix: []const u8,
    jsonl: bool,
};

/// Session stores whose layout follows agent-detect's discovery paths.
/// New harnesses are one row here plus (at most) a message-shape case in normalize.zig.
pub const file_specs = [_]FileSpec{
    .{ .harness = "cline", .root = ".cline/data/sessions", .suffix = ".json", .jsonl = false },
    .{ .harness = "codewhale", .root = ".codewhale/sessions", .suffix = ".json", .jsonl = false },
    .{ .harness = "dsh", .root = ".dsh/sessions", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "zcode", .root = ".zcode/cli/rollout", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "autoclaw", .root = ".openclaw-autoclaw/agents", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "codex", .root = ".codex/sessions", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "claude", .root = ".claude/projects", .suffix = ".jsonl", .jsonl = true },
};

pub const SqlSpec = struct {
    harness: []const u8,
    db: []const u8, // relative to HOME
    sessions_sql: []const u8,
    messages_sql: []const u8, // {s} is replaced with the quoted session id
};

const opencode_sessions =
    \\SELECT id, COALESCE(title,'') AS title, time_created AS time, directory AS cwd, COALESCE(model,'') AS model FROM session_v2 WHERE time_archived IS NULL
    \\UNION ALL
    \\SELECT id, COALESCE(title,'') AS title, time_created, directory, COALESCE(model,'') FROM session WHERE time_archived IS NULL AND id NOT IN (SELECT id FROM session_v2)
    \\
;

const opencode_messages =
    \\SELECT time_created AS time, data AS body FROM message WHERE session_id = {s} ORDER BY time_created
    \\
;

const kilo_sessions =
    \\SELECT id, COALESCE(title,'') AS title, time_created AS time, directory AS cwd, COALESCE(model,'') AS model FROM session WHERE time_archived IS NULL ORDER BY time_created DESC
    \\
;

const kilo_messages =
    \\SELECT time_created AS time, data AS body FROM session_message WHERE session_id = {s} ORDER BY seq, time_created
    \\
;

pub const sql_specs = [_]SqlSpec{
    .{ .harness = "opencode", .db = ".local/share/opencode/opencode.db", .sessions_sql = opencode_sessions, .messages_sql = opencode_messages },
    .{ .harness = "kilo", .db = ".local/share/kilo/kilo.db", .sessions_sql = kilo_sessions, .messages_sql = kilo_messages },
};

pub const Stats = struct {
    scanned: usize = 0,
    exported: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    attachments: usize = 0,
};

fn readBounded(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(@as(u64, limit)));
}

fn parseJson(a: std.mem.Allocator, bytes: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return null;
    return parsed.value;
}

fn sqlQuote(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '\'');
    for (raw) |c| {
        if (c == '\'') try out.append(a, '\'');
        try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}

fn sqliteJson(a: std.mem.Allocator, io: std.Io, db: []const u8, sql: []const u8) ![]u8 {
    const db_z = try a.dupeSentinel(u8, db, 0);
    const sql_z = try a.dupeSentinel(u8, sql, 0);
    var argv = [_][]const u8{ "sqlite3", "-json", "-batch", db_z, sql_z };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SqliteUnavailable,
        else => return error.SqliteSpawnFailed,
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    while (true) {
        var chunk: [8192]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(a, chunk[0..n]);
    }
    const term = child.wait(io) catch return error.SqliteSpawnFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.SqliteError,
        else => return error.SqliteError,
    }
    return out.toOwnedSlice(a);
}

fn rowsOf(a: std.mem.Allocator, bytes: []const u8) []std.json.Value {
    const value = parseJson(a, bytes) orelse return &.{};
    if (value != .array) return &.{};
    return value.array.items;
}

fn titleFromMessages(a: std.mem.Allocator, messages: []const Message, fallback: []const u8) ![]const u8 {
    if (messages.len > 0) {
        const first = messages[0].content;
        const line_end = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
        const line = std.mem.trim(u8, first[0..line_end], " \t#*-_>");
        if (line.len > 0) {
            const end = @min(line.len, 60);
            return try a.dupe(u8, line[0..end]);
        }
    }
    return try a.dupe(u8, fallback);
}

fn collectFile(a: std.mem.Allocator, io: std.Io, spec: FileSpec, path: []const u8, home: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    _ = home;
    stats.scanned += 1;
    const bytes = readBounded(a, io, path, 32 << 20) catch {
        stats.failed += 1;
        return;
    };
    var messages: std.ArrayList(Message) = .empty;
    var attachments: std.ArrayList(Attachment) = .empty;
    var meta: ?std.json.ObjectMap = null;
    var time_raw: []const u8 = "";

    if (spec.jsonl) {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            const value = parseJson(a, trimmed) orelse continue;
            if (value == .object and time_raw.len == 0) time_raw = model.firstTime(value.object);
            try normalize.collectMessages(a, value, &messages, 0);
            try normalize.collectAttachments(a, value, &attachments, 0);
        }
    } else {
        const value = parseJson(a, bytes) orelse {
            stats.failed += 1;
            return;
        };
        if (value == .object) meta = value.object;
        try normalize.collectMessages(a, value, &messages, 0);
        try normalize.collectAttachments(a, value, &attachments, 0);
        if (meta) |obj| {
            time_raw = model.firstTime(obj);
            if (model.jstr(obj, "messages_path")) |messages_path| {
                if (std.fs.path.isAbsolute(messages_path)) {
                    if (readBounded(a, io, messages_path, 32 << 20)) |mb| {
                        var lines = std.mem.splitScalar(u8, mb, '\n');
                        while (lines.next()) |line| {
                            const trimmed = std.mem.trim(u8, line, " \r\t");
                            if (trimmed.len == 0) continue;
                            if (parseJson(a, trimmed)) |v| try normalize.collectMessages(a, v, &messages, 0);
                        }
                    } else |_| {}
                }
            }
        }
    }

    if (messages.items.len == 0) {
        stats.skipped += 1;
        return;
    }
    const fallback = std.fs.path.stem(std.fs.path.basename(path));
    const title = if (meta) |obj| (model.jstr(obj, "title") orelse model.jstr(obj, "name") orelse try titleFromMessages(a, messages.items, fallback)) else try titleFromMessages(a, messages.items, fallback);
    const provider = if (meta) |obj| (model.jstr(obj, "provider") orelse "") else "";
    const model_name = if (meta) |obj| (model.jstr(obj, "model") orelse "") else "";
    const cwd = if (meta) |obj| (model.jstr(obj, "cwd") orelse "") else "";
    try out.append(a, .{
        .id = try a.dupe(u8, std.fs.path.stem(std.fs.path.basename(path))),
        .harness = spec.harness,
        .title = try a.dupe(u8, title),
        .stamp = try model.stamp(a, io, time_raw),
        .provider = try a.dupe(u8, provider),
        .model = try a.dupe(u8, model_name),
        .cwd = try a.dupe(u8, cwd),
        .source_path = try a.dupe(u8, path),
        .messages = try messages.toOwnedSlice(a),
        .attachments = try attachments.toOwnedSlice(a),
    });
    stats.attachments += attachments.items.len;
}

fn walkDir(a: std.mem.Allocator, io: std.Io, path: []const u8, spec: FileSpec, home: []const u8, out: *std.ArrayList(Session), stats: *Stats) void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => walkDir(a, io, child, spec, home, out, stats),
            .file => {
                if (std.mem.endsWith(u8, entry.name, spec.suffix)) {
                    collectFile(a, io, spec, child, home, out, stats) catch { stats.failed += 1; };
                }
            },
            else => {},
        }
    }
}

pub fn collectFileSessions(a: std.mem.Allocator, io: std.Io, home: []const u8, out: *std.ArrayList(Session), stats: *Stats, only: []const u8) !void {
    for (file_specs) |spec| {
        if (only.len > 0 and !std.mem.eql(u8, only, spec.harness)) continue;
        const root = try std.fs.path.join(a, &.{ home, spec.root });
        walkDir(a, io, root, spec, home, out, stats);
    }
}

fn rowsForSession(a: std.mem.Allocator, io: std.Io, spec: SqlSpec, db: []const u8, id: []const u8) ![]const std.json.Value {
    const quoted = try sqlQuote(a, id);
    const sql = try std.mem.replaceOwned(u8, a, spec.messages_sql, "{s}", quoted);
    const bytes = try sqliteJson(a, io, db, sql);
    return rowsOf(a, bytes);
}

pub fn collectSqlSessions(a: std.mem.Allocator, io: std.Io, home: []const u8, out: *std.ArrayList(Session), stats: *Stats, only: []const u8) !void {
    for (sql_specs) |spec| {
        if (only.len > 0 and !std.mem.eql(u8, only, spec.harness)) continue;
        const db = try std.fs.path.join(a, &.{ home, spec.db });
        if (std.Io.Dir.cwd().statFile(io, db, .{})) |_| {} else |_| continue;
        const bytes = sqliteJson(a, io, db, spec.sessions_sql) catch |err| {
            if (err == error.SqliteUnavailable) return err;
            stats.failed += 1;
            continue;
        };
        const rows = rowsOf(a, bytes);
        for (rows) |row| {
            if (row != .object) continue;
            const obj = row.object;
            const id = model.jstr(obj, "id") orelse continue;
            stats.scanned += 1;
            var messages: std.ArrayList(Message) = .empty;
            var attachments: std.ArrayList(Attachment) = .empty;
            const msg_rows = rowsForSession(a, io, spec, db, id) catch {
                stats.failed += 1;
                continue;
            };
            for (msg_rows) |msg_row| {
                if (msg_row != .object) continue;
                const mo = msg_row.object;
                const time = model.firstTime(mo);
                if (mo.get("body")) |body| {
                    if (body == .string) {
                        if (parseJson(a, body.string)) |parsed| {
                            try normalize.collectMessages(a, parsed, &messages, 0);
                            try normalize.collectAttachments(a, parsed, &attachments, 0);
                        }
                    }
                }
                if (mo.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        const role = model.jstr(mo, "role") orelse "user";
                        try messages.append(a, .{ .role = role, .content = content.string, .time = time });
                    }
                }
            }
            if (messages.items.len == 0) {
                stats.skipped += 1;
                continue;
            }
            const title = model.jstr(obj, "title") orelse try titleFromMessages(a, messages.items, id);
            try out.append(a, .{
                .id = try a.dupe(u8, id),
                .harness = spec.harness,
                .title = try a.dupe(u8, title),
                .stamp = try model.stamp(a, io, model.firstTime(obj)),
                .provider = "",
                .model = model.jstr(obj, "model") orelse "",
                .cwd = model.jstr(obj, "cwd") orelse "",
                .source_path = try std.fmt.allocPrint(a, "{s}#{s}", .{ db, id }),
                .messages = try messages.toOwnedSlice(a),
                .attachments = try attachments.toOwnedSlice(a),
            });
            stats.attachments += attachments.items.len;
        }
    }
}
