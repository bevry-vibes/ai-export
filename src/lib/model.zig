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
    provider: []const u8 = "",
    model: []const u8 = "",
};

pub const Attachment = struct {
    title: []const u8 = "attachment",
    source_path: []const u8 = "",
    extension: []const u8 = "bin",
    data: []const u8 = "",
};

pub const Session = struct {
    id: []const u8,
    harness: []const u8,
    title: []const u8,
    stamp: []const u8,
    provider: []const u8 = "",
    model: []const u8 = "",
    cwd: []const u8 = "",
    team: []const u8 = "",
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

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const shifted = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * shifted + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Parse the common ISO-8601 shape `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM]`.
fn isoSecs(raw: []const u8) ?i64 {
    if (raw.len < 19) return null;
    if (raw[4] != '-' or raw[7] != '-' or (raw[10] != 'T' and raw[10] != ' ')) return null;
    const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, raw[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, raw[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, raw[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, raw[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, raw[17..19], 10) catch return null;
    var secs = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    var i: usize = 19;
    if (i < raw.len and raw[i] == '.') {
        i += 1;
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
    }
    if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) {
        const sign: i64 = if (raw[i] == '+') -1 else 1;
        if (i + 6 > raw.len) return null;
        const oh = std.fmt.parseInt(i64, raw[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, raw[i + 4 .. i + 6], 10) catch return null;
        secs += sign * (oh * 3600 + om * 60);
    }
    return secs;
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
        } else if (isoSecs(raw)) |parsed| {
            if (parsed >= 0) secs = @intCast(parsed);
        }
    }
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_secs: u64 = if (now_ns > 0) @intCast(@divTrunc(now_ns, std.time.ns_per_s)) else 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs orelse now_secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}-{d:0>2}", .{
        yd.year,
        @backingInt(md.month),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    });
}

/// Keep titles human: spaces and punctuation stay, filesystem-hostile bytes go.
pub fn humanTitle(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pending_space = false;
    for (raw) |c| {
        if (c < 0x20 or c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or c == '"' or c == '<' or c == '>' or c == '|') {
            pending_space = out.items.len > 0;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space and out.items.len > 0) try out.append(a, ' ');
        pending_space = false;
        if (out.items.len < 70) try out.append(a, c);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(a, "Untitled session");
    return out.toOwnedSlice(a);
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

fn nested(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

/// First timestamp-looking value, including common nested `metadata` / `payload`
/// objects. Caller owns the returned string only when it came from an integer.
pub fn firstTime(obj: std.json.ObjectMap) []const u8 {
    const keys = [_][]const u8{ "createdAt", "created_at", "time_created", "timestamp", "startedAt", "started_at", "updatedAt", "updated_at", "time", "ts" };
    for (keys) |key| {
        if (jstr(obj, key)) |v| return v;
        if (jint(obj, key)) |n| {
            return std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{n}) catch "";
        }
    }
    const containers = [_][]const u8{ "metadata", "payload", "time", "info" };
    for (containers) |key| {
        if (nested(obj, key)) |inner| {
            const found = firstTime(inner);
            if (found.len > 0) return found;
        }
    }
    return "";
}

pub fn titleOf(obj: std.json.ObjectMap) []const u8 {
    if (jstr(obj, "title")) |v| return v;
    if (jstr(obj, "name")) |v| return v;
    if (nested(obj, "metadata")) |meta| {
        if (jstr(meta, "title")) |v| return v;
    }
    return "";
}

pub fn idOf(obj: std.json.ObjectMap) []const u8 {
    const keys = [_][]const u8{ "session_id", "sessionId", "id", "uuid", "traceId", "requestId" };
    for (keys) |key| {
        if (jstr(obj, key)) |v| return v;
    }
    if (nested(obj, "metadata")) |meta| {
        for (keys) |key| {
            if (jstr(meta, key)) |v| return v;
        }
    }
    if (nested(obj, "payload")) |payload| {
        for (keys) |key| {
            if (jstr(payload, key)) |v| return v;
        }
    }
    return "";
}

/// Short deterministic suffix from a full session id.
pub fn shortId(a: std.mem.Allocator, id: []const u8) ![]u8 {
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, id));
    return std.fmt.allocPrint(a, "{x:0>8}", .{hash});
}
