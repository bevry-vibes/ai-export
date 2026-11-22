// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");
const model = @import("model.zig");

const Session = model.Session;
const ManifestEntry = struct {
    source: []const u8,
    hash: u64,
    md: []const u8,
    json: []const u8,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    attachments_dir: []const u8,
    manifest_path: []const u8,
    entries: std.ArrayList(ManifestEntry) = .empty,
    written: usize = 0,
    skipped: usize = 0,
    attachment_count: usize = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, output: []const u8) !Writer {
        const attach = try std.fs.path.join(a, &.{ output, "attachments" });
        const manifest = try std.fs.path.join(a, &.{ output, ".ai-export-sync-manifest.tsv" });
        var self = Writer{
            .allocator = a,
            .io = io,
            .output = output,
            .attachments_dir = attach,
            .manifest_path = manifest,
        };
        try std.Io.Dir.cwd().createDirPath(io, attach);
        self.readManifest() catch {};
        return self;
    }

    fn readManifest(self: *Writer) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.manifest_path, self.allocator, @enumFromInt(@as(u64, 4 << 20))) catch return;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const source = fields.next() orelse continue;
            const hash_raw = fields.next() orelse continue;
            const md = fields.next() orelse continue;
            const json = fields.next() orelse continue;
            const hash = std.fmt.parseInt(u64, hash_raw, 10) catch continue;
            try self.entries.append(self.allocator, .{
                .source = try self.allocator.dupe(u8, source),
                .hash = hash,
                .md = try self.allocator.dupe(u8, md),
                .json = try self.allocator.dupe(u8, json),
            });
        }
    }

    fn previous(self: *Writer, source: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.source, source)) return i;
        }
        return null;
    }

    fn exists(self: *Writer, path: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    fn nameFor(self: *Writer, session: Session) !struct { stem: []const u8, md: []const u8, json: []const u8 } {
        const a = self.allocator;
        const slug = try model.slug(a, session.title);
        const base = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ session.stamp, session.harness, slug });
        var candidate = try a.dupe(u8, base);
        var n: usize = 2;
        while (self.exists(try std.fmt.allocPrint(a, "{s}/{s}.md", .{ self.output, candidate }))) {
            candidate = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
            n += 1;
        }
        return .{
            .stem = candidate,
            .md = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ self.output, candidate }),
            .json = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ self.output, candidate }),
        };
    }

    fn markdown(self: *Writer, session: Session) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const a = self.allocator;
        var turn: usize = 0;
        for (session.messages) |message| {
            if (!std.mem.eql(u8, message.role, "user") and !std.mem.eql(u8, message.role, "assistant")) continue;
            if (std.mem.eql(u8, message.role, "user")) turn += 1;
            const label = if (std.mem.eql(u8, message.role, "user"))
                try std.fmt.allocPrint(a, "### {d}. Prompt", .{turn})
            else
                try std.fmt.allocPrint(a, "### {d}. Answer", .{if (turn == 0) 1 else turn});
            if (out.items.len > 0) try out.append(a, '\n');
            try out.appendSlice(a, label);
            try out.appendSlice(a, "\n\n");
            try out.appendSlice(a, message.content);
            try out.append(a, '\n');
        }
        return out.toOwnedSlice(a);
    }

    fn put(a: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
        try obj.put(a, key, .{ .string = value });
    }

    fn jsonDocument(self: *Writer, session: Session, attachments: []const []const u8) ![]u8 {
        const a = self.allocator;
        var root = std.json.ObjectMap.empty;
        try put(a, &root, "schema", "ai-export-sync/1");
        var info = std.json.ObjectMap.empty;
        try put(a, &info, "id", session.id);
        try put(a, &info, "title", session.title);
        try put(a, &info, "harness", session.harness);
        try put(a, &info, "provider", session.provider);
        try put(a, &info, "model", session.model);
        try put(a, &info, "cwd", session.cwd);
        try put(a, &info, "source_path", session.source_path);
        try put(a, &info, "stamp", session.stamp);
        try root.put(a, "session", .{ .object = info });

        var counts = std.json.ObjectMap.empty;
        try counts.put(a, "messages", .{ .integer = @intCast(session.messages.len) });
        try counts.put(a, "attachments", .{ .integer = @intCast(attachments.len) });
        try root.put(a, "counts", .{ .object = counts });

        var att_array = std.json.Array.init(a);
        for (session.attachments, 0..) |att, i| {
            var item = std.json.ObjectMap.empty;
            try put(a, &item, "title", att.title);
            try put(a, &item, "source_path", att.source_path);
            try put(a, &item, "extension", att.extension);
            if (i < attachments.len) try put(a, &item, "output_path", attachments[i]);
            try att_array.append(.{ .object = item });
        }
        try root.put(a, "attachments", .{ .array = att_array });

        var msg_array = std.json.Array.init(a);
        for (session.messages) |message| {
            var item = std.json.ObjectMap.empty;
            try put(a, &item, "role", message.role);
            try put(a, &item, "time", message.time);
            try put(a, &item, "content", message.content);
            try msg_array.append(.{ .object = item });
        }
        try root.put(a, "messages", .{ .array = msg_array });
        const doc: std.json.Value = .{ .object = root };
        return std.json.Stringify.valueAlloc(a, doc, .{ .whitespace = .indent_2 });
    }

    fn copyAttachments(self: *Writer, session: Session) ![][]const u8 {
        const a = self.allocator;
        var outputs: std.ArrayList([]const u8) = .empty;
        for (session.attachments) |att| {
            const source = att.source_path;
            if (source.len == 0) continue;
            var resolved = source;
            if (!std.fs.path.isAbsolute(source)) {
                if (session.cwd.len > 0) {
                    resolved = std.fs.path.join(a, &.{ session.cwd, source }) catch source;
                }
            }
            if (std.Io.Dir.cwd().statFile(self.io, resolved, .{})) |_| {} else |_| continue;
            const att_slug = try model.slug(a, std.fs.path.stem(att.title));
            const base = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ session.stamp, session.harness, att_slug });
            var name = try std.fmt.allocPrint(a, "{s}.{s}", .{ base, att.extension });
            var n: usize = 2;
            while (self.exists(try std.fmt.allocPrint(a, "{s}/{s}", .{ self.attachments_dir, name }))) {
                name = try std.fmt.allocPrint(a, "{s}-{d}.{s}", .{ base, n, att.extension });
                n += 1;
            }
            const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.attachments_dir, name });
            std.Io.Dir.cwd().copyFile(resolved, std.Io.Dir.cwd(), dest, self.io, .{}) catch continue;
            try outputs.append(a, dest);
            self.attachment_count += 1;
        }
        return outputs.toOwnedSlice(a);
    }

    pub fn writeSession(self: *Writer, session: Session) !bool {
        const a = self.allocator;
        const digest = model.hashMessages(session.messages, session.attachments);
        if (self.previous(session.source_path)) |i| {
            const old = self.entries.items[i];
            if (old.hash == digest and self.exists(old.md) and self.exists(old.json)) {
                self.skipped += 1;
                return false;
            }
            std.Io.Dir.cwd().deleteFile(self.io, old.md) catch {};
            std.Io.Dir.cwd().deleteFile(self.io, old.json) catch {};
            _ = self.entries.orderedRemove(i);
        }

        const names = try self.nameFor(session);
        const outputs = try self.copyAttachments(session);
        const md = try self.markdown(session);
        const doc = try self.jsonDocument(session, outputs);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = names.md, .data = md });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = names.json, .data = doc });
        try self.entries.append(a, .{
            .source = try a.dupe(u8, session.source_path),
            .hash = digest,
            .md = names.md,
            .json = names.json,
        });
        self.written += 1;
        return true;
    }

    pub fn saveManifest(self: *Writer) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.entries.items) |entry| {
            const line = try std.fmt.allocPrint(self.allocator, "{s}\t{d}\t{s}\t{s}\n", .{ entry.source, entry.hash, entry.md, entry.json });
            try out.appendSlice(self.allocator, line);
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.manifest_path, .data = out.items });
    }
};
