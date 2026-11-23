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

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    written: usize = 0,
    attachment_count: usize = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, output: []const u8, purge: bool) !Writer {
        try std.Io.Dir.cwd().createDirPath(io, output);
        var self = Writer{ .allocator = a, .io = io, .output = output };
        if (purge) try self.clean();
        return self;
    }

    /// Every run is a full regeneration: wipe previous harness exports so a format
    /// change never leaves two generations of files side by side.
    fn clean(self: *Writer) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.output, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            // The archives catalogue is source data, not a generated harness
            // export — keep it. Everything else is regenerated from scratch.
            if (std.mem.eql(u8, entry.name, "archives") or std.mem.eql(u8, entry.name, "cache") or std.mem.startsWith(u8, entry.name, "state.")) continue;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output, entry.name });
            switch (entry.kind) {
                .file => std.Io.Dir.cwd().deleteFile(self.io, path) catch {},
                .directory => std.Io.Dir.cwd().deleteTree(self.io, path) catch {},
                else => {},
            }
        }
    }

    fn harnessDir(self: *Writer, harness: []const u8, quarantined: bool) ![]const u8 {
        const root = if (quarantined)
            try std.fs.path.join(self.allocator, &.{ self.output, "duplicates", harness })
        else
            try std.fs.path.join(self.allocator, &.{ self.output, harness });
        try std.Io.Dir.cwd().createDirPath(self.io, root);
        return root;
    }

    fn base(self: *Writer, session: Session) ![]const u8 {
        const a = self.allocator;
        const title = try model.humanTitle(a, session.title);
        const short = try model.shortId(a, session.id);
        return std.fmt.allocPrint(a, "{s} - {s} - {s}", .{ session.stamp, short, title });
    }

    fn markdown(self: *Writer, session: Session) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const a = self.allocator;
        for (session.messages) |message| {
            if (!std.mem.eql(u8, message.role, "user") and !std.mem.eql(u8, message.role, "assistant")) continue;
            var label: []const u8 = "### Prompt";
            if (std.mem.eql(u8, message.role, "assistant")) {
                const id = if (message.model.len > 0) message.model else session.model;
                const prov = if (message.provider.len > 0) message.provider else session.provider;
                label = if (id.len == 0)
                    "### Answer"
                else if (prov.len > 0)
                    try std.fmt.allocPrint(a, "### Answer — {s}/{s}", .{ prov, id })
                else
                    try std.fmt.allocPrint(a, "### Answer — {s}", .{id});
            }
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
        try put(a, &root, "schema", "ai-export/2");

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
            try put(a, &item, "provider", message.provider);
            try put(a, &item, "model", message.model);
            try put(a, &item, "content", message.content);
            try msg_array.append(.{ .object = item });
        }
        try root.put(a, "messages", .{ .array = msg_array });

        const doc: std.json.Value = .{ .object = root };
        return std.json.Stringify.valueAlloc(a, doc, .{ .whitespace = .indent_2 });
    }

    fn copyAttachments(self: *Writer, session: Session, root: []const u8) ![][]const u8 {
        const a = self.allocator;
        const short = try model.shortId(a, session.id);
        var outputs: std.ArrayList([]const u8) = .empty;
        var attachments_dir: ?[]const u8 = null;
        for (session.attachments) |att| {
            const source = att.source_path;
            if (source.len == 0) continue;
            var resolved = source;
            if (!std.fs.path.isAbsolute(source) and session.cwd.len > 0) {
                resolved = std.fs.path.join(a, &.{ session.cwd, source }) catch source;
            }
            const remote = std.mem.startsWith(u8, resolved, "http://") or std.mem.startsWith(u8, resolved, "https://");
            if (remote and att.data.len == 0) continue;
            if (!remote) {
                if (std.Io.Dir.cwd().statFile(self.io, resolved, .{})) |_| {} else |_| continue;
            }
            const att_title = try model.humanTitle(a, std.fs.path.stem(att.title));
            const name = try std.fmt.allocPrint(a, "{s} - {s} - {s}.{s}", .{ session.stamp, short, att_title, att.extension });
            if (attachments_dir == null) {
                const dir = try std.fs.path.join(a, &.{ root, "attachments" });
                try std.Io.Dir.cwd().createDirPath(self.io, dir);
                attachments_dir = dir;
            }
            const dest = try std.fs.path.join(a, &.{ attachments_dir.?, name });
            if (remote) {
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = att.data }) catch continue;
            } else {
                std.Io.Dir.cwd().copyFile(resolved, std.Io.Dir.cwd(), dest, self.io, .{}) catch continue;
            }
            try outputs.append(a, dest);
            self.attachment_count += 1;
        }
        return outputs.toOwnedSlice(a);
    }

    pub fn writeSession(self: *Writer, session: Session) !void {
        const a = self.allocator;
        const root = try self.harnessDir(session.harness, session.quarantined);
        const json_dir = try std.fs.path.join(a, &.{ root, "json" });
        try std.Io.Dir.cwd().createDirPath(self.io, json_dir);
        const stem = try self.base(session);
        const outputs = try self.copyAttachments(session, root);
        const md = try self.markdown(session);
        const doc = try self.jsonDocument(session, outputs);
        const md_path = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ root, stem });
        const json_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ json_dir, stem });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = md_path, .data = md });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = json_path, .data = doc });
        self.written += 1;
    }
};
