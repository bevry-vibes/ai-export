// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");
const testing = std.testing;
const model = @import("lib/model.zig");
const normalize = @import("lib/normalize.zig");
const dedupe = @import("lib/dedupe.zig");

fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    return parsed.value;
}

test "slug collapses punctuation and caps length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hello-world", try model.slug(a, "Hello, World!"));
    try testing.expectEqualStrings("a-b", try model.slug(a, "  a / b  "));
    try testing.expectEqualStrings("untitled", try model.slug(a, "!!!"));
}

test "stamp formats epoch milliseconds as UTC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("2026-11-22 00-00", try model.stamp(arena.allocator(), std.testing.io, "1795305600000"));
}

test "stamp parses ISO-8601 timestamps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("2026-11-22 10-51", try model.stamp(arena.allocator(), std.testing.io, "2026-11-22T10:51:09.123Z"));
    try testing.expectEqualStrings("2026-11-22 03-51", try model.stamp(arena.allocator(), std.testing.io, "2026-11-22T10:51:09+07:00"));
}

test "shortId is stable and fixed width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try model.shortId(a, "session-123");
    try testing.expectEqual(@as(usize, 8), one.len);
    try testing.expectEqualStrings(one, try model.shortId(a, "session-123"));
}

test "dedupe collapses exact within-harness copies and reports cross-harness copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]model.Message{
        .{ .role = "user", .content = "one two three four" },
        .{ .role = "assistant", .content = "answer one" },
        .{ .role = "user", .content = "five six seven eight" },
        .{ .role = "assistant", .content = "answer two" },
    };
    var sessions: std.ArrayList(model.Session) = .empty;
    try sessions.append(a, .{ .id = "a", .harness = "claude", .title = "Chat", .stamp = "2026-01-01 00-00", .source_path = "a", .messages = &msgs });
    try sessions.append(a, .{ .id = "a", .harness = "claude", .title = "Chat", .stamp = "2026-01-01 00-00", .source_path = "a2", .messages = &msgs });
    try sessions.append(a, .{ .id = "b", .harness = "chatgpt", .title = "Chat", .stamp = "2026-01-01 00-00", .source_path = "b", .messages = &msgs });
    const result = try dedupe.process(a, &sessions);
    try testing.expectEqual(@as(usize, 2), sessions.items.len);
    try testing.expectEqual(@as(usize, 1), result.collapsed);
    try testing.expectEqual(@as(usize, 1), result.duplicates.len);
    try testing.expectEqualStrings("exact", result.duplicates[0].kind);
}

test "collectMessages reads role and content pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try parse(a, 
        \\{"messages":[{"role":"user","content":"hello"},{"role":"assistant","content":"hi"}]}
    );
    var out: std.ArrayList(model.Message) = .empty;
    try normalize.collectMessages(a, value, &out, 0);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("user", out.items[0].role);
    try testing.expectEqualStrings("hello", out.items[0].content);
    try testing.expectEqualStrings("assistant", out.items[1].role);
}

test "collectMessages folds nested payload and block content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try parse(a, 
        \\{"type":"event_msg","payload":{"type":"user_message","message":[{"type":"input_text","text":"first"},{"type":"input_text","text":"second"}]}}
    );
    var out: std.ArrayList(model.Message) = .empty;
    try normalize.collectMessages(a, value, &out, 0);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("user", out.items[0].role);
    try testing.expectEqualStrings("first\nsecond", out.items[0].content);
}

test "collectAttachments picks up file paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try parse(a, 
        \\{"attachments":[{"path":"/tmp/photo.png","title":"Photo"}]}
    );
    var out: std.ArrayList(model.Attachment) = .empty;
    try normalize.collectAttachments(a, value, &out, 0);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("photo.png", out.items[0].title);
    try testing.expectEqualStrings("png", out.items[0].extension);
}
