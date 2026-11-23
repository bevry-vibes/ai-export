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
const readers = @import("readers.zig");

const Session = model.Session;
const Message = model.Message;
const Stats = readers.Stats;

fn runCapture(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .ignore }) catch return error.ArchiveToolUnavailable;
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
    const term = child.wait(io) catch return error.ArchiveToolUnavailable;
    switch (term) {
        .exited => |code| if (code != 0) return error.ArchiveUnreadable,
        else => return error.ArchiveUnreadable,
    }
    return out.toOwnedSlice(a);
}

fn parse(a: std.mem.Allocator, bytes: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return null;
    return parsed.value;
}

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, @enumFromInt(@as(u64, 128 << 20)));
}

fn addSession(a: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Session), stats: *Stats, source: []const u8, harness: []const u8, id_raw: []const u8, title_raw: []const u8, time_raw: []const u8, messages: []const Message) !void {
    if (messages.len == 0) {
        stats.skipped += 1;
        return;
    }
    const title = if (title_raw.len > 0) title_raw else id_raw;
    var id = id_raw;
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, ' ') != null) {
        var h = std.hash.Wyhash.init(0);
        h.update(harness);
        h.update(title);
        if (messages.len > 0) h.update(messages[0].content);
        id = try std.fmt.allocPrint(a, "{s}-{x:0>8}", .{ harness, @as(u32, @truncate(h.final())) });
    }
    try out.append(a, .{
        .id = try a.dupe(u8, id),
        .harness = harness,
        .title = try a.dupe(u8, title),
        .stamp = try model.stamp(a, io, time_raw),
        .source_path = try a.dupe(u8, source),
        .messages = messages,
    });
    stats.scanned += 1;
}

fn collectMessagesOf(a: std.mem.Allocator, value: std.json.Value) ![]Message {
    var list: std.ArrayList(Message) = .empty;
    try normalize.collectMessages(a, value, &list, 0);
    return list.toOwnedSlice(a);
}

fn ingestTypingMindChat(a: std.mem.Allocator, io: std.Io, chat: std.json.Value, source: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    if (chat != .object) return;
    const obj = chat.object;
    const id = model.idOf(obj);
    const fallback = model.jstr(obj, "preview") orelse "typingmind chat";
    const title = model.jstr(obj, "chatTitle") orelse fallback;
    const messages = try collectMessagesOf(a, chat);
    try addSession(a, io, out, stats, source, "typingmind", if (id.len > 0) id else fallback, title, model.firstTime(obj), messages);
}

fn ingestClaude(a: std.mem.Allocator, io: std.Io, value: std.json.Value, source: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    if (value != .array) return;
    for (value.array.items) |conv| {
        if (conv != .object) continue;
        const obj = conv.object;
        const id = model.idOf(obj);
        const title = model.jstr(obj, "name") orelse model.jstr(obj, "title") orelse id;
        const messages = try collectMessagesOf(a, conv);
        try addSession(a, io, out, stats, source, "claude", if (id.len > 0) id else title, title, model.firstTime(obj), messages);
    }
}

fn ingestChatGpt(a: std.mem.Allocator, io: std.Io, value: std.json.Value, source: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    if (value != .array) return;
    for (value.array.items) |conv| {
        if (conv != .object) continue;
        const obj = conv.object;
        const found_id = model.idOf(obj);
        const id = if (found_id.len > 0) found_id else (model.jstr(obj, "conversation_id") orelse "chatgpt chat");
        const title = model.jstr(obj, "title") orelse id;
        var time_raw = model.firstTime(obj);
        if (model.jint(obj, "create_time")) |secs| {
            time_raw = try std.fmt.allocPrint(a, "{d}", .{@as(u64, @intCast(secs)) * 1000});
        }
        const ChatMsg = struct { time: f64, role: []const u8, content: []const u8 };
        var collected: std.ArrayList(ChatMsg) = .empty;
        if (obj.get("mapping")) |mapping| {
            if (mapping == .object) {
                var it = mapping.object.iterator();
                while (it.next()) |entry| {
                    const node = entry.value_ptr.*;
                    if (node != .object) continue;
                    const message = node.object.get("message") orelse continue;
                    if (message != .object) continue;
                    const author = message.object.get("author") orelse continue;
                    if (author != .object) continue;
                    const role_raw = model.jstr(author.object, "role") orelse continue;
                    const role = if (std.mem.eql(u8, role_raw, "user")) "user" else if (std.mem.eql(u8, role_raw, "assistant")) "assistant" else continue;
                    const content = message.object.get("content") orelse continue;
                    if (content != .object) continue;
                    const parts = content.object.get("parts") orelse continue;
                    const text = try normalize.contentText(a, parts, 0);
                    if (text.len == 0) continue;
                    var created: f64 = 0;
                    if (message.object.get("create_time")) |ct| {
                        created = switch (ct) {
                            .float => |f| f,
                            .integer => |n| @floatFromInt(n),
                            else => 0,
                        };
                    }
                    try collected.append(a, .{ .time = created, .role = role, .content = text });
                }
            }
        }
        // The export's mapping object is not chronological; sort by the
        // message's own create_time before emitting the transcript.
        std.mem.sort(ChatMsg, collected.items, {}, struct {
            fn lessThan(_: void, x: ChatMsg, y: ChatMsg) bool {
                return x.time < y.time;
            }
        }.lessThan);
        var messages: std.ArrayList(Message) = .empty;
        for (collected.items) |m| try messages.append(a, .{ .role = m.role, .content = m.content });
        try addSession(a, io, out, stats, source, "chatgpt", id, title, time_raw, try messages.toOwnedSlice(a));
    }
}

fn ingestJson(a: std.mem.Allocator, io: std.Io, bytes: []const u8, source: []const u8, out: *std.ArrayList(Session), stats: *Stats) void {
    const value = parse(a, bytes) orelse {
        stats.failed += 1;
        return;
    };
    if (value == .object) {
        const data = value.object.get("data") orelse value;
        if (data == .object) {
            if (data.object.get("chats")) |chats| {
                if (chats == .array) {
                    for (chats.array.items) |chat| ingestTypingMindChat(a, io, chat, source, out, stats) catch { stats.failed += 1; };
                    return;
                }
            }
        }
    } else if (value == .array and value.array.items.len > 0) {
        const first = value.array.items[0];
        if (first == .object) {
            if (first.object.get("chat_messages") != null) {
                ingestClaude(a, io, value, source, out, stats) catch { stats.failed += 1; };
                return;
            }
            if (first.object.get("mapping") != null or first.object.get("create_time") != null) {
                ingestChatGpt(a, io, value, source, out, stats) catch { stats.failed += 1; };
                return;
            }
        }
    }
    stats.skipped += 1;
}

fn isZip(bytes: []const u8) bool {
    return bytes.len >= 4 and bytes[0] == 'P' and bytes[1] == 'K' and bytes[2] == 3 and bytes[3] == 4;
}

fn catalogFile(a: std.mem.Allocator, io: std.Io, source: []const u8, catalog_root: []const u8, harness: []const u8, stamp: []const u8, rel: []const u8) void {
    _ = a;
    _ = io;
    _ = source;
    _ = catalog_root;
    _ = harness;
    _ = stamp;
    _ = rel;
    // Relocation is a maintainer action, not a CLI side effect.
}

fn writeExtracted(a: std.mem.Allocator, io: std.Io, catalog_root: []const u8, harness: []const u8, stamp: []const u8, member: []const u8, bytes: []const u8) void {
    const name = std.fs.path.basename(member);
    const generic = std.mem.eql(u8, name, "conversations.json") or std.mem.eql(u8, name, "data.json") or std.mem.startsWith(u8, name, "conversations-");
    const final_name = if (generic)
        std.fmt.allocPrint(a, "{s} - {s} - {s}", .{ stamp, harness, name }) catch name
    else
        name;
    const parent = std.fs.path.dirname(member) orelse "";
    const dest = if (parent.len > 0)
        std.fs.path.join(a, &.{ catalog_root, parent, final_name }) catch return
    else
        std.fs.path.join(a, &.{ catalog_root, final_name }) catch return;
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest) orelse catalog_root) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes }) catch {};
}

fn trashZip(a: std.mem.Allocator, io: std.Io, path: []const u8) void {
    _ = runCapture(a, io, &.{ "/usr/bin/trash", "-s", path }) catch return;
}

fn trashZipsUnder(a: std.mem.Allocator, io: std.Io, root: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => trashZipsUnder(a, io, path),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zip")) trashZip(a, io, path);
            },
            else => {},
        }
    }
}

fn harnessForPath(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "claude-memory") != null or std.mem.indexOf(u8, path, "claude-data") != null or std.mem.indexOf(u8, path, "claude") != null) return "claude";
    if (std.mem.indexOf(u8, path, "typingmind") != null) return "typingmind";
    if (std.mem.indexOf(u8, path, "chatgpt") != null or std.mem.indexOf(u8, path, "conversations-000") != null) return "chatgpt";
    return "mixed";
}

fn catalogTree(a: std.mem.Allocator, io: std.Io, root: []const u8, archives_root: []const u8, stamp: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => catalogTree(a, io, path, archives_root, stamp),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zip") or std.mem.eql(u8, entry.name, ".DS_Store")) continue;
                const harness = harnessForPath(path);
                if (std.mem.eql(u8, harness, "mixed") and std.mem.indexOf(u8, path, "manifest-") != null) continue;
                const folder = std.fmt.allocPrint(a, "{s} - {s}", .{ stamp, harness }) catch continue;
                const dest_root = std.fs.path.join(a, &.{ archives_root, folder }) catch continue;
                var rel = path;
                if (std.mem.startsWith(u8, path, root)) rel = path[root.len + 1 ..];
                catalogFile(a, io, path, dest_root, harness, stamp, rel);
            },
            else => {},
        }
    }
}

fn removeLegacyMixed(a: std.mem.Allocator, io: std.Io, archives_root: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, archives_root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or !std.mem.endsWith(u8, entry.name, " - mixed")) continue;
        const path = std.fs.path.join(a, &.{ archives_root, entry.name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
}

/// Import every transcript found under an already-relocated exports catalogue.
/// No copying, no zip handling, no real harness stores — the catalogue is the
/// single source for this mode.
pub fn collectFromArchives(a: std.mem.Allocator, io: std.Io, archives_root: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(a, try a.dupe(u8, archives_root));
    while (pending.items.len > 0) {
        const dir_path = pending.pop().?;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const path = try std.fs.path.join(a, &.{ dir_path, entry.name });
            switch (entry.kind) {
                .directory => try pending.append(a, path),
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                    if (std.mem.eql(u8, entry.name, ".title-cache.tsv") or std.mem.startsWith(u8, entry.name, "duplicates") or std.mem.startsWith(u8, entry.name, "conflicts")) continue;
                    const bytes = readFile(a, io, path) catch {
                        stats.failed += 1;
                        continue;
                    };
                    ingestJson(a, io, bytes, path, out, stats);
                },
                else => {},
            }
        }
    }
}

pub fn collectArchives(a: std.mem.Allocator, io: std.Io, paths: []const []const u8, out: *std.ArrayList(Session), stats: *Stats, catalog_root: []const u8, trash_enabled: bool) !void {
    removeLegacyMixed(a, io, catalog_root);
    for (paths) |path| {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            stats.failed += 1;
            continue;
        };
        const stamp = try model.stamp(a, io, try std.fmt.allocPrint(a, "{d}", .{@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)}));
        if (stat.kind == .directory) {
            // Claude memory exports are documents, not chats: catalogue only.
            catalogTree(a, io, path, catalog_root, stamp);
            var walker = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
            defer walker.close(io);
            var it = walker.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
                const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name });
                if (std.mem.startsWith(u8, entry.name, "manifest-") or std.mem.eql(u8, entry.name, "metadata.json")) continue;
                const bytes = readFile(a, io, child) catch continue;
                ingestJson(a, io, bytes, child, out, stats);
            }
            // Extracted exports are catalogued; the transport zips are not
            // needed any more. Trash (recoverable) rather than unlink.
            if (trash_enabled) trashZipsUnder(a, io, path);
            const parent = std.fs.path.dirname(path) orelse "";
            if (parent.len > 0) {
                const base = std.fs.path.basename(path);
                const sibling = std.fmt.allocPrint(a, "{s}/{s}.zip", .{ parent, base }) catch "";
                if (sibling.len > 0) {
                    if (std.Io.Dir.cwd().statFile(io, sibling, .{})) |_| { if (trash_enabled) trashZip(a, io, sibling); } else |_| {}
                }
            }
            continue;
        }

        const bytes = readFile(a, io, path) catch {
            stats.failed += 1;
            continue;
        };
        const harness = if (isZip(bytes)) "chatgpt" else if (std.mem.indexOf(u8, path, "claude") != null) "claude" else harnessForPath(path);
        const folder = try std.fmt.allocPrint(a, "{s} - {s}", .{ stamp, harness });
        const catalog = try std.fs.path.join(a, &.{ catalog_root, folder });
        if (isZip(bytes)) {
            const listing = runCapture(a, io, &.{ "unzip", "-Z1", path }) catch {
                stats.failed += 1;
                continue;
            };
            var extracted: usize = 0;
            var lines = std.mem.splitScalar(u8, listing, '\n');
            while (lines.next()) |line| {
                const member = std.mem.trim(u8, line, " \r");
                if (!std.mem.endsWith(u8, member, ".json")) continue;
                const member_bytes = runCapture(a, io, &.{ "unzip", "-p", path, member }) catch continue;
                writeExtracted(a, io, catalog, harness, stamp, member, member_bytes);
                extracted += 1;
                if (std.mem.indexOf(u8, member, "conversation") != null or std.mem.indexOf(u8, member, "chat") != null) {
                    ingestJson(a, io, member_bytes, try std.fmt.allocPrint(a, "{s}::{s}", .{ path, member }), out, stats);
                }
            }
            if (extracted > 0 and trash_enabled) trashZip(a, io, path);
        } else {
            catalogFile(a, io, path, catalog, harness, stamp, std.fs.path.basename(path));
            ingestJson(a, io, bytes, path, out, stats);
        }
    }
}
