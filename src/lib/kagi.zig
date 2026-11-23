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
const progress = @import("progress.zig");

const Session = model.Session;
const Stats = readers.Stats;
const api = "https://assistant.kagi.com/api";

fn parse(a: std.mem.Allocator, bytes: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return null;
    return parsed.value;
}

const Fetch = struct {
    io: std.Io,
    a: std.mem.Allocator,
    cookie: ?[]const u8,
    cache_root: []const u8,

    /// curl with a hard timeout: a stalled Kagi request must never hang the
    /// whole export. The cookie goes in an argv header on this local machine.
    fn get(self: *Fetch, path: []const u8) ![]u8 {
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
            path
        else
            try std.fmt.allocPrint(self.a, "{s}{s}", .{ api, path });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a, &.{ "curl", "--silent", "--show-error", "--fail", "--max-time", "20", "--compressed", "-A", "ai-export/1.0", "-H", "Accept: application/json" });
        if (self.cookie) |token| {
            try argv.append(self.a, "-H");
            try argv.append(self.a, try std.fmt.allocPrint(self.a, "Cookie: kagi_session={s}", .{token}));
        }
        try argv.append(self.a, url);
        var child = std.process.spawn(self.io, .{ .argv = argv.items, .stdout = .pipe, .stderr = .ignore }) catch return error.KagiRequestFailed;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        var buf: [8192]u8 = undefined;
        var reader = child.stdout.?.reader(self.io, &buf);
        while (true) {
            var chunk: [8192]u8 = undefined;
            const n = reader.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(self.a, chunk[0..n]);
        }
        const term = child.wait(self.io) catch return error.KagiRequestFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.KagiHttpError,
            else => return error.KagiRequestFailed,
        }
        return out.toOwnedSlice(self.a);
    }

    /// Cached remote read. Callers choose the key so branch changes (new
    /// prompts, revived threads) naturally miss the cache and refetch.
    fn getCached(self: *Fetch, url: []const u8, key: []const u8, fallback_prefix: []const u8) ![]u8 {
        const dir = try std.fs.path.join(self.a, &.{ self.cache_root, "kagi" });
        const path = try std.fs.path.join(self.a, &.{ dir, key });
        if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, @enumFromInt(@as(u64, 128 << 20)))) |bytes| return bytes else |_| {}
        const bytes = self.get(url) catch {
            // Request failed: reuse the newest raw response cached for this
            // endpoint/branch even if its revision key has changed.
            var fallback_dir = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return error.KagiRequestFailed;
            defer fallback_dir.close(self.io);
            var it = fallback_dir.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.startsWith(u8, entry.name, fallback_prefix)) continue;
                const stale_path = try std.fs.path.join(self.a, &.{ dir, entry.name });
                if (std.Io.Dir.cwd().readFileAlloc(self.io, stale_path, self.a, @enumFromInt(@as(u64, 128 << 20)))) |old| return old else |_| {}
            }
            return error.KagiRequestFailed;
        };
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
        return bytes;
    }
};

fn itemsOf(value: std.json.Value, key: []const u8) []const std.json.Value {
    if (value == .object) {
        if (value.object.get(key)) |v| {
            if (v == .array) return v.array.items;
        }
    }
    if (value == .array) return value.array.items;
    return &.{};
}

fn nestedItems(value: std.json.Value, outer: []const u8, inner: []const u8) []const std.json.Value {
    if (value != .object) return &.{};
    const box = value.object.get(outer) orelse return &.{};
    if (box == .object) {
        if (box.object.get(inner)) |v| {
            if (v == .array) return v.array.items;
        }
    }
    if (box == .array) return box.array.items;
    return &.{};
}

fn fetchAttachments(a: std.mem.Allocator, fetch: ?*Fetch, item: std.json.Value, out: *std.ArrayList(model.Attachment)) !void {
    const f = fetch orelse return;
    if (item != .object) return;
    const atts = item.object.get("attachments") orelse return;
    if (atts != .array) return;
    for (atts.array.items) |att| {
        if (att != .object) continue;
        const rel = model.jstr(att.object, "url") orelse continue;
        const filename = model.jstr(att.object, "filename") orelse model.jstr(att.object, "original_filename") orelse "attachment";
        const mime = model.jstr(att.object, "mime_type") orelse "";
        var ext = std.fs.path.extension(filename);
        if (ext.len > 1) ext = ext[1..] else if (std.mem.indexOfScalar(u8, mime, '/')) |slash| ext = mime[slash + 1 ..] else ext = "bin";
        const url = if (std.mem.startsWith(u8, rel, "/"))
            try std.fmt.allocPrint(a, "https://assistant.kagi.com{s}", .{rel})
        else
            rel;
        const key = try std.fmt.allocPrint(a, "attachment-{x}-{s}.bin", .{ @as(u64, @truncate(std.hash.Wyhash.hash(0, url))), ext });
        const bytes = f.getCached(url, key, try std.fmt.allocPrint(a, "attachment-{x}-", .{ @as(u64, @truncate(std.hash.Wyhash.hash(0, url))) })) catch continue;
        try out.append(a, .{
            .title = try a.dupe(u8, model.jstr(att.object, "original_filename") orelse filename),
            .source_path = url,
            .extension = try a.dupe(u8, ext),
            .data = bytes,
        });
    }
}

fn addMessages(a: std.mem.Allocator, fetch: ?*Fetch, items: []const std.json.Value, out: *std.ArrayList(model.Message), attachments: *std.ArrayList(model.Attachment)) !void {
    for (items) |item| {
        if (item != .object) continue;
        var messages: std.ArrayList(model.Message) = .empty;
        try normalize.collectMessages(a, item, &messages, 0);
        for (messages.items) |m| try out.append(a, m);
        try fetchAttachments(a, fetch, item, attachments);
    }
}

fn addBranch(a: std.mem.Allocator, io: std.Io, fetch: *Fetch, branch: std.json.Value, title: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    if (branch != .object) return;
    const branch_id = model.idOf(branch.object);
    if (branch_id.len == 0) return;
    var messages: std.ArrayList(model.Message) = .empty;
    var attachments: std.ArrayList(model.Attachment) = .empty;
    var before: []const u8 = "";
    var page: usize = 0;
    while (page < 20) : (page += 1) {
        const path = if (before.len > 0)
            try std.fmt.allocPrint(a, "/branches/{s}/messages?limit=100&before={s}", .{ branch_id, before })
        else
            try std.fmt.allocPrint(a, "/branches/{s}/messages?limit=100", .{branch_id});
        const revision = model.firstTime(branch.object);
        const cache_key = try std.fmt.allocPrint(a, "messages-{s}-{s}-{d}.json", .{ branch_id, if (revision.len > 0) revision else "none", @as(u64, @intCast(branch.object.count())) });
        const bytes = fetch.getCached(path, cache_key, try std.fmt.allocPrint(a, "messages-{s}-", .{branch_id})) catch break;
        const value = parse(a, bytes) orelse break;
        const page_items = nestedItems(value, "messages", "items");
        if (page_items.len == 0) break;
        try addMessages(a, fetch, page_items, &messages, &attachments);
        var oldest: []const u8 = "";
        for (page_items) |item| {
            if (item != .object) continue;
            const id = model.idOf(item.object);
            const time = model.firstTime(item.object);
            if (oldest.len == 0 or (time.len > 0 and oldest.len > 0 and std.mem.order(u8, time, oldest) == .lt)) {
                oldest = time;
                if (id.len > 0) before = id;
            }
        }
        const has_more = if (value == .object)
            (value.object.get("messages") orelse value).object.get("has_more") != null
        else
            false;
        if (!has_more) break;
    }
    if (messages.items.len == 0) {
        stats.skipped += 1;
        return;
    }
    stats.scanned += 1;
    try out.append(a, .{
        .id = try a.dupe(u8, branch_id),
        .harness = "kagi",
        .title = try a.dupe(u8, if (title.len > 0) title else branch_id),
        .stamp = try model.stamp(a, io, model.firstTime(branch.object)),
        .source_path = try std.fmt.allocPrint(a, "kagi://branch/{s}", .{branch_id}),
        .messages = try messages.toOwnedSlice(a),
        .attachments = try attachments.toOwnedSlice(a),
    });
}

pub fn collectKagi(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.ArrayList(Session), stats: *Stats, tracker: ?*progress.Tracker, cache_root: []const u8) !void {
    const token = env.get("KAGI_SESSION") orelse return;
    if (std.mem.trim(u8, token, " \t\r\n").len == 0) return;

    var fetch = Fetch{ .io = io, .a = a, .cookie = token, .cache_root = cache_root };
    

    // Enumerate the full conversation list with the web app's after_id cursor.
    // /init only carries the first 50 rows; /api/conversations pages by 100.
    var after_id: []const u8 = "";
    var seen = std.StringHashMap(void).init(a);
    var page: usize = 0;
    var total: usize = 0;
    while (page < 50) : (page += 1) {
        const path = if (after_id.len > 0)
            try std.fmt.allocPrint(a, "/conversations?limit=100&after_id={s}", .{after_id})
        else
            "/conversations?limit=100";
        const bytes = fetch.get(path) catch break;
        const value = parse(a, bytes) orelse break;
        var rows = itemsOf(value, "conversations");
        if (rows.len == 0 and value == .object) rows = itemsOf(value, "items");
        if (rows.len == 0) break;
        for (rows) |conv| {
            if (conv != .object) continue;
            const id = model.idOf(conv.object);
            if (id.len == 0) continue;
            if (seen.contains(id)) continue;
            try seen.put(try a.dupe(u8, id), {});
            total += 1;
            if (tracker) |t| try t.note("kagi:conversations", total, 0);

            const title = model.titleOf(conv.object);
            const branch_bytes = fetch.get(try std.fmt.allocPrint(a, "/conversations/{s}/branches", .{id})) catch {
                stats.failed += 1;
                continue;
            };
            const branch_value = parse(a, branch_bytes) orelse {
                stats.failed += 1;
                continue;
            };
            const branches = itemsOf(branch_value, "branches");
            for (branches) |branch| addBranch(a, io, &fetch, branch, title, out, stats) catch { stats.failed += 1; };
        }
        var has_more = false;
        if (value == .object) {
            const cursor_field = value.object.get("conversations") orelse value;
            if (cursor_field == .object) {
                if (cursor_field.object.get("has_more")) |hm| has_more = hm == .bool and hm.bool;
            }
        }
        if (!has_more) break;
        after_id = try a.dupe(u8, model.idOf(rows[rows.len - 1].object));
        if (after_id.len == 0) break;
    }
    if (total == 0) return error.KagiNoConversationList;
}

pub fn collectShare(a: std.mem.Allocator, io: std.Io, share_uuid: []const u8, out: *std.ArrayList(Session), stats: *Stats, cache_root: []const u8) !void {
    var fetch = Fetch{ .io = io, .a = a, .cookie = null, .cache_root = cache_root };
    
    const bytes = try fetch.get(try std.fmt.allocPrint(a, "/shares/{s}", .{share_uuid}));
    const value = parse(a, bytes) orelse return error.KagiShareUnreadable;
    if (value != .object) return;
    const conv = value.object.get("conversation") orelse return;
    const title = if (conv == .object) model.titleOf(conv.object) else "";
    var messages: std.ArrayList(model.Message) = .empty;
    var attachments: std.ArrayList(model.Attachment) = .empty;
    try addMessages(a, &fetch, itemsOf(value, "messages"), &messages, &attachments);
    if (messages.items.len == 0) {
        stats.skipped += 1;
        return;
    }
    stats.scanned += 1;
    try out.append(a, .{
        .id = try a.dupe(u8, share_uuid),
        .harness = "kagi",
        .title = try a.dupe(u8, if (title.len > 0) title else share_uuid),
        .stamp = try model.stamp(a, io, if (conv == .object) model.firstTime(conv.object) else ""),
        .source_path = try std.fmt.allocPrint(a, "kagi://share/{s}", .{share_uuid}),
        .messages = try messages.toOwnedSlice(a),
        .attachments = try attachments.toOwnedSlice(a),
    });
}
