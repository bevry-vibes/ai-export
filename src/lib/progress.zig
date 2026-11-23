// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");

pub const Tracker = struct {
    a: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    output: []const u8,
    phase: []const u8 = "starting",
    started_ns: i128,
    last_ns: i128,
    cadence_ns: i128 = @as(i128, 10) * std.time.ns_per_s,
    total: usize = 0,
    processed: usize = 0,
    exported: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    attachments: usize = 0,
    titled: usize = 0,
    noise_filtered: usize = 0,
    collapsed: usize = 0,
    merged: usize = 0,
    duplicates: usize = 0,
    conflicts: usize = 0,

    pub fn now(io: std.Io) i128 {
        return std.Io.Timestamp.now(io, .real).nanoseconds;
    }

    fn put(a: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
        try obj.put(a, key, .{ .string = value });
    }

    fn writeUnlocked(self: *Tracker) !void {
        const a = std.heap.page_allocator;
        const ns = now(self.io);
        self.last_ns = ns;
        const elapsed_ns = @max(ns - self.started_ns, 0);
        var eta_ns: i128 = 0;
        if (self.total > self.processed and self.processed > 0) {
            eta_ns = @divTrunc(elapsed_ns, @as(i128, @intCast(self.processed))) * @as(i128, @intCast(self.total - self.processed));
        }
        var root = std.json.ObjectMap.empty;
        try put(a, &root, "phase", self.phase);
        try put(a, &root, "updated_at", try std.fmt.allocPrint(a, "{d}", .{ns}));
        try root.put(a, "cadence_seconds", .{ .integer = 10 });
        try root.put(a, "total", .{ .integer = @intCast(self.total) });
        try root.put(a, "processed", .{ .integer = @intCast(self.processed) });
        try root.put(a, "exported", .{ .integer = @intCast(self.exported) });
        try root.put(a, "skipped", .{ .integer = @intCast(self.skipped) });
        try root.put(a, "failed", .{ .integer = @intCast(self.failed) });
        try root.put(a, "attachments", .{ .integer = @intCast(self.attachments) });
        try root.put(a, "titled", .{ .integer = @intCast(self.titled) });
        try root.put(a, "noise_filtered", .{ .integer = @intCast(self.noise_filtered) });
        try root.put(a, "collapsed", .{ .integer = @intCast(self.collapsed) });
        try root.put(a, "merged", .{ .integer = @intCast(self.merged) });
        try root.put(a, "duplicates", .{ .integer = @intCast(self.duplicates) });
        try root.put(a, "conflicts", .{ .integer = @intCast(self.conflicts) });
        try root.put(a, "elapsed_seconds", .{ .float = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s) });
        try root.put(a, "eta_seconds", .{ .float = @as(f64, @floatFromInt(eta_ns)) / @as(f64, std.time.ns_per_s) });
        const value: std.json.Value = .{ .object = root };
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
        const path = try std.fs.path.join(a, &.{ self.output, "state.json" });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }

    pub fn write(self: *Tracker) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        try self.writeUnlocked();
    }

    pub fn maybe(self: *Tracker) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (now(self.io) - self.last_ns >= self.cadence_ns) try self.writeUnlocked();
    }

    pub fn note(self: *Tracker, phase: []const u8, processed: usize, total: usize) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.phase = phase;
        self.processed = processed;
        if (total > 0) self.total = total;
        if (now(self.io) - self.last_ns >= self.cadence_ns) try self.writeUnlocked();
    }

    pub fn tick(self: *Tracker, processed: usize, total: usize) !void {
        try self.note(self.phase, processed, total);
    }

    fn heartbeat(self: *Tracker) void {
        while (self.running.load(.seq_cst)) {
            std.Io.sleep(self.io, .{ .nanoseconds = @as(i128, 10) * std.time.ns_per_s }, .real) catch return;
            if (!self.running.load(.seq_cst)) break;
            self.maybe() catch {};
        }
    }

    pub fn start(self: *Tracker) !std.Thread {
        return std.Thread.spawn(.{}, Tracker.heartbeat, .{self});
    }

    pub fn stop(self: *Tracker) void {
        self.running.store(false, .seq_cst);
    }
};

