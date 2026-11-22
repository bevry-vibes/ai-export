// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");

pub const Message = struct {
    role: []const u8 = "unknown",
    content: []const u8 = "",
    time: []const u8 = "",
};

pub const Attachment = struct {
    title: []const u8 = "attachment",
    source_path: []const u8 = "",
    extension: []const u8 = "bin",
};

pub const Session = struct {
    id: []const u8,
    harness: []const u8,
    title: []const u8,
    stamp: []const u8,
    provider: []const u8 = "",
    model: []const u8 = "",
    cwd: []const u8 = "",
    source_path: []const u8,
    messages: []const Message = &.{},
    attachments: []const Attachment = &.{},
};

pub fn jstr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn jint(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

/// Lowercase slug for file names: runs of non-alphanumerics become one dash.
pub fn slug(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pending_dash = false;
    for (raw) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and out.items.len > 0) try out.append(a, '-');
            pending_dash = false;
            if (out.items.len < 60) try out.append(a, lower);
        } else {
            pending_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(a, "untitled");
    return out.toOwnedSlice(a);
}

/// Filesystem-safe UTC timestamp: YYYYMMDDTHHMMSSZ.
pub fn stamp(a: std.mem.Allocator, io: std.Io, raw: []const u8) ![]u8 {
    var secs: ?u64 = null;
    if (raw.len > 0) {
        var all_digits = true;
        for (raw) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            const value = std.fmt.parseInt(u64, raw, 10) catch 0;
            secs = if (value > 100_000_000_000) @intCast(@divTrunc(value, 1000)) else value;
        }
    }
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_secs: u64 = if (now_ns > 0) @intCast(@divTrunc(now_ns, std.time.ns_per_s)) else 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs orelse now_secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        @backingInt(md.month),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// Stable hash of the export payload: used to skip sessions that did not change.
pub fn hashMessages(messages: []const Message, attachments: []const Attachment) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (messages) |m| {
        hasher.update(m.role);
        hasher.update(m.content);
        hasher.update(m.time);
    }
    for (attachments) |att| {
        hasher.update(att.title);
        hasher.update(att.source_path);
    }
    return hasher.final();
}

/// First timestamp-looking string found in an object, across common spellings.
pub fn firstTime(obj: std.json.ObjectMap) []const u8 {
    const keys = [_][]const u8{ "createdAt", "created_at", "time_created", "timestamp", "startedAt", "started_at", "updatedAt", "updated_at", "time" };
    for (keys) |key| {
        if (jstr(obj, key)) |v| return v;
        if (jint(obj, key)) |n| {
            return std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{n}) catch "";
        }
    }
    return "";
}
