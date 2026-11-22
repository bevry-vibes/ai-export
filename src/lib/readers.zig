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
    .{ .harness = "dsh", .root = ".dsh/sessions", .suffix = ".jsonl.zstd", .jsonl = true },
    .{ .harness = "zcode", .root = ".zcode/cli/rollout", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "autoclaw", .root = ".openclaw-autoclaw/agents", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "codex", .root = ".codex/sessions", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "claude", .root = ".claude/projects", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "pi", .root = ".pi/agent/sessions", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "qwen", .root = ".qwen/projects", .suffix = ".jsonl", .jsonl = true },
    .{ .harness = "reasonix", .root = ".reasonix/projects", .suffix = ".jsonl", .jsonl = true },
};

pub const SqlSpec = struct {
    harness: []const u8,
    db: []const u8, // relative to HOME (ignored when discover_root is set)
    sessions_sql: []const u8,
    messages_sql: []const u8, // {s} is replaced with the quoted session id
    discover_root: []const u8 = "",
    discover_suffix: []const u8 = "",
};

const opencode_sessions =
    \\SELECT id, COALESCE(title,slug,'') AS title, time_created AS time, directory AS cwd, COALESCE(model,'') AS model FROM session_v2 WHERE time_archived IS NULL
    \\UNION ALL
    \\SELECT p.session_id AS id, COALESCE(s.title,s.slug,'') AS title, MIN(p.time_created) AS time, s.directory AS cwd, COALESCE(s.model,'') AS model FROM part p JOIN session s ON s.id = p.session_id WHERE s.id NOT IN (SELECT id FROM session_v2) GROUP BY p.session_id
    \\
;

// OpenCode v2 keeps prompts/answers in session_message.data; the legacy 13
// sessions keep them in part.data. Select display text only — never dump the
// whole `data` blob, which can carry tool input with credentials.
const opencode_messages =
    \\SELECT sm.time_created AS time, sm.type AS role,
    \\  CASE WHEN sm.type = 'user' THEN json_extract(sm.data,'$.text')
    \\       ELSE (SELECT group_concat(json_extract(je.value,'$.text'), char(10))
    \\             FROM json_each(json_extract(sm.data,'$.content')) je
    \\             WHERE json_extract(je.value,'$.type') = 'text' AND json_extract(je.value,'$.text') IS NOT NULL)
    \\  END AS content
    \\FROM session_message sm WHERE sm.session_id = {s} AND sm.type IN ('user','assistant')
    \\UNION ALL
    \\SELECT p.time_created AS time, json_extract(m.data,'$.role') AS role,
    \\  json_extract(p.data,'$.text') AS content
    \\FROM part p JOIN message m ON m.id = p.message_id
    \\WHERE p.session_id = {s} AND json_extract(p.data,'$.type') = 'text'
    \\ORDER BY time
    \\
;

const kilo_sessions =
    \\SELECT id, COALESCE(title,slug,'') AS title, time_created AS time, directory AS cwd, COALESCE(model,'') AS model FROM session WHERE time_archived IS NULL ORDER BY time_created DESC
    \\
;

const kilo_messages =
    \\SELECT m.time_created AS time, json_extract(m.data,'$.role') AS role,
    \\  json_extract(p.data,'$.text') AS content
    \\FROM part p JOIN message m ON m.id = p.message_id
    \\WHERE p.session_id = {s} AND json_extract(p.data,'$.type') = 'text'
    \\  AND json_extract(p.data,'$.text') IS NOT NULL
    \\ORDER BY time
    \\
;

const anythingllm_sessions =
    \\SELECT t.id, COALESCE(t.name,'') AS title, MIN(c.createdAt) AS time,
    \\  COALESCE(w.name,'') AS cwd, '' AS model
    \\FROM workspace_threads t
    \\LEFT JOIN workspaces w ON w.id = t.workspace_id
    \\LEFT JOIN workspace_chats c ON c.thread_id = t.id
    \\GROUP BY t.id
    \\
;

const anythingllm_messages =
    \\SELECT c.createdAt AS time, 'user' AS role, c.prompt AS content
    \\FROM workspace_chats c WHERE c.thread_id = {s} AND c.prompt IS NOT NULL
    \\UNION ALL
    \\SELECT c.lastUpdatedAt AS time, 'assistant' AS role,
    \\  COALESCE(json_extract(c.response,'$.text'), c.response) AS content
    \\FROM workspace_chats c WHERE c.thread_id = {s} AND c.response IS NOT NULL
    \\ORDER BY time
    \\
;

const goose_sessions =
    \\SELECT id, COALESCE(name,'') AS title, created_at AS time,
    \\  COALESCE(working_dir,'') AS cwd, '' AS model FROM sessions
    \\
;

const goose_messages =
    \\SELECT m.created_timestamp AS time, m.role AS role,
    \\  (SELECT group_concat(json_extract(je.value,'$.text'), char(10))
    \\   FROM json_each(m.content_json) je
    \\   WHERE json_extract(je.value,'$.type') = 'text') AS content
    \\FROM messages m WHERE m.session_id = {s}
    \\
;

const crush_sessions =
    \\SELECT id, COALESCE(title,'') AS title, created_at AS time, '' AS cwd, '' AS model FROM sessions
    \\
;

const crush_messages =
    \\SELECT m.created_at AS time, m.role AS role,
    \\  (SELECT group_concat(json_extract(je.value,'$.data.text'), char(10))
    \\   FROM json_each(m.parts) je
    \\   WHERE json_extract(je.value,'$.type') = 'text') AS content
    \\FROM messages m WHERE m.session_id = {s}
    \\
;

const copilot_sessions =
    \\SELECT id, COALESCE(summary,'') AS title, created_at AS time,
    \\  COALESCE(cwd,'') AS cwd, COALESCE(agent_name,'') AS model FROM sessions
    \\
;

const copilot_messages =
    \\SELECT t.timestamp AS time, 'user' AS role, t.user_message AS content
    \\FROM turns t WHERE t.session_id = {s} AND t.user_message IS NOT NULL
    \\UNION ALL
    \\SELECT t.timestamp AS time, 'assistant' AS role, t.assistant_response AS content
    \\FROM turns t WHERE t.session_id = {s} AND t.assistant_response IS NOT NULL
    \\ORDER BY time
    \\
;

pub const sql_specs = [_]SqlSpec{
    .{ .harness = "opencode", .db = ".local/share/opencode/opencode.db", .sessions_sql = opencode_sessions, .messages_sql = opencode_messages },
    .{ .harness = "kilo", .db = ".local/share/kilo/kilo.db", .sessions_sql = kilo_sessions, .messages_sql = kilo_messages },
    .{ .harness = "anythingllm", .db = "Library/Application Support/anythingllm-desktop/storage/anythingllm.db", .sessions_sql = anythingllm_sessions, .messages_sql = anythingllm_messages },
    .{ .harness = "goose", .db = ".local/share/goose/sessions/sessions.db", .sessions_sql = goose_sessions, .messages_sql = goose_messages },
    .{ .harness = "crush", .db = "", .sessions_sql = crush_sessions, .messages_sql = crush_messages, .discover_root = "Projects", .discover_suffix = ".crush/crush.db" },
    .{ .harness = "copilot", .db = "Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db", .sessions_sql = copilot_sessions, .messages_sql = copilot_messages },
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

fn sqlId(a: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    if (model.jstr(obj, "id")) |v| return v;
    if (model.jint(obj, "id")) |n| return std.fmt.allocPrint(a, "{d}", .{n}) catch null;
    return null;
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
    // Control preambles ("user input mode", "AGENTS.md instructions", context
    // summaries) make terrible file names. Prefer the first genuine prompt.
    const noise = [_][]const u8{ "user input mode", "agents.md", "context summary", "<system", "<environment", "this is a tool result" };
    for (messages) |message| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        const first = message.content;
        const line_end = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
        const line = std.mem.trim(u8, first[0..line_end], " \t#*-_>");
        if (line.len == 0) continue;
        var skip = false;
        for (noise) |prefix| {
            if (std.ascii.startsWithIgnoreCase(line, prefix)) skip = true;
        }
        if (skip) continue;
        const end = @min(line.len, 40);
        return try a.dupe(u8, line[0..end]);
    }
    return try a.dupe(u8, fallback);
}

fn collectFile(a: std.mem.Allocator, io: std.Io, spec: FileSpec, path: []const u8, home: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    _ = home;
    stats.scanned += 1;
    var bytes = readBounded(a, io, path, 64 << 20) catch {
        stats.failed += 1;
        return;
    };
    if (std.mem.endsWith(u8, path, ".zstd")) {
        var input: std.Io.Reader = .fixed(bytes);
        var z = std.compress.zstd.Decompress.init(&input, &.{}, .{});
        bytes = z.reader.allocRemaining(a, .limited64(64 << 20)) catch {
            stats.failed += 1;
            return;
        };
    }
    var messages: std.ArrayList(Message) = .empty;
    var attachments: std.ArrayList(Attachment) = .empty;
    var meta: ?std.json.ObjectMap = null;
    var time_raw: []const u8 = "";
    // Last resort for stores without a timestamp field: the file's own mtime
    // keeps each session on its own date instead of collapsing onto "now".
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.mtime.nanoseconds > 0) {
            time_raw = try std.fmt.allocPrint(a, "{d}", .{@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)});
        }
    } else |_| {}

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
            const declared_time = model.firstTime(obj);
            if (declared_time.len > 0) time_raw = declared_time;
            if (model.jstr(obj, "messages_path")) |messages_path| {
                if (std.fs.path.isAbsolute(messages_path)) {
                    if (readBounded(a, io, messages_path, 64 << 20)) |mb| {
                        // Cline writes one pretty-printed JSON object here, not
                        // JSONL — parse the whole file in one go.
                        if (parseJson(a, mb)) |v| {
                            try normalize.collectMessages(a, v, &messages, 0);
                            try normalize.collectAttachments(a, v, &attachments, 0);
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
    const declared_title = if (meta) |obj| model.titleOf(obj) else "";
    const session_id = if (meta) |obj| model.idOf(obj) else "";
    const title = if (declared_title.len > 0)
        try a.dupe(u8, declared_title)
    else
        try titleFromMessages(a, messages.items, fallback);
    const provider = if (meta) |obj| (model.jstr(obj, "provider") orelse "") else "";
    const model_name = if (meta) |obj| (model.jstr(obj, "model") orelse "") else "";
    const cwd = if (meta) |obj| (model.jstr(obj, "cwd") orelse "") else "";
    try out.append(a, .{
        .id = try a.dupe(u8, if (session_id.len > 0) session_id else fallback),
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
                // Cline's `*.messages.json` is the message body of the
                // companion session `*.json`; importing both duplicates it and
                // loses the richer session metadata.
                if (std.mem.eql(u8, spec.harness, "cline") and
                    (std.mem.endsWith(u8, entry.name, ".messages.json") or std.mem.endsWith(u8, entry.name, ".compaction.json"))) continue;
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

fn walkDbs(a: std.mem.Allocator, io: std.Io, path: []const u8, suffix: []const u8, out: *std.ArrayList([]const u8)) void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => walkDbs(a, io, child, suffix, out),
            .file => {
                if (std.mem.endsWith(u8, child, suffix)) out.append(a, child) catch {};
            },
            else => {},
        }
    }
}

pub fn collectSqlSessions(a: std.mem.Allocator, io: std.Io, home: []const u8, out: *std.ArrayList(Session), stats: *Stats, only: []const u8) !void {
    for (sql_specs) |spec| {
        if (only.len > 0 and !std.mem.eql(u8, only, spec.harness)) continue;
        var dbs: std.ArrayList([]const u8) = .empty;
        if (spec.discover_root.len > 0) {
            const root = try std.fs.path.join(a, &.{ home, spec.discover_root });
            walkDbs(a, io, root, spec.discover_suffix, &dbs);
        } else {
            try dbs.append(a, try std.fs.path.join(a, &.{ home, spec.db }));
        }
        for (dbs.items) |db| {
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
                const id = sqlId(a, obj) orelse continue;
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
                const title = model.titleOf(obj);
                const final_title = if (title.len > 0) title else try titleFromMessages(a, messages.items, id);
                try out.append(a, .{
                    .id = try a.dupe(u8, id),
                    .harness = spec.harness,
                    .title = try a.dupe(u8, final_title),
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
}
