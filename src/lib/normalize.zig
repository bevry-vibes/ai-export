// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");
const model = @import("model.zig");

const Message = model.Message;
const Attachment = model.Attachment;

fn roleOf(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "user") or std.mem.eql(u8, raw, "human") or
        std.mem.eql(u8, raw, "user_message") or std.mem.eql(u8, raw, "prompt")) return "user";
    if (std.mem.eql(u8, raw, "assistant") or std.mem.eql(u8, raw, "agent") or
        std.mem.eql(u8, raw, "ai") or std.mem.eql(u8, raw, "model") or
        std.mem.eql(u8, raw, "agent_message")) return "assistant";
    return null;
}

fn appendText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (out.items.len > 0) try out.append(a, '\n');
    try out.appendSlice(a, text);
}

/// Flatten a message body (string, block array, or nested object) into plain text.
pub fn contentText(a: std.mem.Allocator, value: std.json.Value, depth: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    switch (value) {
        .string => |s| try appendText(a, &out, s),
        .array => |arr| {
            for (arr.items) |item| {
                const piece = try contentText(a, item, depth + 1);
                if (piece.len > 0) try appendText(a, &out, piece);
            }
        },
        .object => |obj| {
            const keys = [_][]const u8{ "text", "content", "message", "parts", "value" };
            for (keys) |key| {
                if (obj.get(key)) |item| {
                    const piece = try contentText(a, item, depth + 1);
                    if (piece.len > 0) try appendText(a, &out, piece);
                }
            }
        },
        else => {},
    }
    return out.toOwnedSlice(a);
}

fn addMessage(a: std.mem.Allocator, out: *std.ArrayList(Message), role: []const u8, body: std.json.Value, time: []const u8) !void {
    const text = try contentText(a, body, 0);
    if (text.len == 0) return;
    try out.append(a, .{ .role = role, .content = text, .time = time });
}

/// Walk a parsed transcript and collect user/assistant messages in file order.
pub fn collectMessages(a: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(Message), depth: u8) !void {
    if (depth > 24) return;
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| try collectMessages(a, item, out, depth + 1);
        },
        .object => |obj| {
            var role: ?[]const u8 = null;
            if (model.jstr(obj, "role")) |raw| role = roleOf(raw);
            if (role == null) {
                if (model.jstr(obj, "type")) |raw| role = roleOf(raw);
            }
            if (role == null) {
                if (model.jstr(obj, "sender")) |raw| role = roleOf(raw);
            }
            if (role == null) {
                if (obj.get("payload")) |payload| {
                    if (payload == .object) {
                        if (model.jstr(payload.object, "type")) |raw| role = roleOf(raw);
                    }
                }
            }
            if (role) |r| {
                var body = obj.get("content") orelse obj.get("message") orelse obj.get("text");
                if (body == null) {
                    if (obj.get("payload")) |payload| {
                        if (payload == .object) body = payload.object.get("message") orelse payload.object.get("content");
                    }
                }
                if (body) |b| {
                    const time = model.firstTime(obj);
                    try addMessage(a, out, r, b, time);
                    return;
                }
            }
            // transcript envelopes hold messages under these keys
            const keys = [_][]const u8{ "messages", "chat_messages", "records", "data", "payload", "session", "conversation", "chat", "thread", "message", "request", "response", "body" };
            for (keys) |key| {
                if (obj.get(key)) |item| try collectMessages(a, item, out, depth + 1);
            }
        },
        else => {},
    }
}

fn addPath(a: std.mem.Allocator, out: *std.ArrayList(Attachment), raw: []const u8) !void {
    if (raw.len == 0 or raw.len > 4096) return;
    if (std.mem.indexOfScalar(u8, raw, '\n') != null) return;
    const base = std.fs.path.basename(raw);
    if (base.len == 0) return;
    var ext = std.fs.path.extension(base);
    if (ext.len > 1) ext = ext[1..] else ext = "bin";
    try out.append(a, .{
        .title = try a.dupe(u8, base),
        .source_path = try a.dupe(u8, raw),
        .extension = try a.dupe(u8, ext),
    });
}

/// Collect file paths mentioned in attachment-like fields.
pub fn collectAttachments(a: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(Attachment), depth: u8) !void {
    if (depth > 24) return;
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| try collectAttachments(a, item, out, depth + 1);
        },
        .object => |obj| {
            const path_keys = [_][]const u8{ "path", "file_path", "filepath", "filename", "filePath", "url" };
            for (path_keys) |key| {
                if (model.jstr(obj, key)) |raw| {
                    if (std.mem.startsWith(u8, raw, "/") or std.mem.indexOf(u8, raw, "://") == null) {
                        try addPath(a, out, raw);
                    }
                }
            }
            const keys = [_][]const u8{ "attachments", "files", "images", "message", "messages", "content", "parts", "payload", "data", "records" };
            for (keys) |key| {
                if (obj.get(key)) |item| try collectAttachments(a, item, out, depth + 1);
            }
        },
        else => {},
    }
}
