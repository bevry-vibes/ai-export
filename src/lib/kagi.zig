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
const Stats = readers.Stats;
const api = "https://assistant.kagi.com/api";

fn parse(a: std.mem.Allocator, bytes: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return null;
    return parsed.value;
}

const Fetch = struct {
    client: std.http.Client,
    a: std.mem.Allocator,
    cookie: ?[]const u8,

    fn get(self: *Fetch, path: []const u8) ![]u8 {
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
            path
        else
            try std.fmt.allocPrint(self.a, "{s}{s}", .{ api, path });
        var headers: [1]std.http.Header = undefined;
        var headers_slice: []const std.http.Header = &.{};
        if (self.cookie) |token| {
            headers[0] = .{ .name = "Cookie", .value = try std.fmt.allocPrint(self.a, "kagi_session={s}", .{token}) };
            headers_slice = headers[0..1];
        }
        var out = std.Io.Writer.Allocating.init(self.a);
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &out.writer,
            .extra_headers = headers_slice,
        });
        if (result.status.class() != .success) return error.KagiHttpError;
        return out.written();
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
        const bytes = f.get(url) catch continue;
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
        const bytes = fetch.get(path) catch break;
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

pub fn collectKagi(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.ArrayList(Session), stats: *Stats) !void {
    const token = env.get("KAGI_SESSION") orelse return;
    if (std.mem.trim(u8, token, " \t\r\n").len == 0) return;

    var fetch = Fetch{ .client = .{ .allocator = a, .io = io }, .a = a, .cookie = token };
    defer fetch.client.deinit();

    // The client repo documents per-conversation endpoints; enumerate through
    // the list endpoint, trying the known spellings.
    var conversations: []const std.json.Value = &.{};
    // The web app's own init payload carries the first page of conversations.
    const list_paths = [_][]const u8{ "/init", "/conversations?limit=100", "/conversations", "/conversations/list" };
    for (list_paths) |path| {
        const bytes = fetch.get(path) catch continue;
        const value = parse(a, bytes) orelse continue;
        var rows = itemsOf(value, "conversations");
        if (rows.len == 0) rows = nestedItems(value, "conversations", "items");
        if (rows.len > 0) {
            conversations = rows;
            break;
        }
    }
    if (conversations.len == 0) {
        return error.KagiNoConversationList;
    }
    if (env.get("KAGI_DEBUG") != null) {
        std.Io.File.stderr().writeStreamingAll(io, std.fmt.allocPrint(a, "kagi: {d} conversations\n", .{conversations.len}) catch "") catch {};
    }

    for (conversations) |conv| {
        if (conv != .object) continue;
        const conv_id = model.idOf(conv.object);
        if (conv_id.len == 0) continue;
        const title = model.titleOf(conv.object);
        const branch_bytes = fetch.get(try std.fmt.allocPrint(a, "/conversations/{s}/branches", .{conv_id})) catch {
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
}

pub fn collectShare(a: std.mem.Allocator, io: std.Io, share_uuid: []const u8, out: *std.ArrayList(Session), stats: *Stats) !void {
    var fetch = Fetch{ .client = .{ .allocator = a, .io = io }, .a = a, .cookie = null };
    defer fetch.client.deinit();
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
