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

pub const Duplicate = struct {
    a_harness: []const u8,
    a_id: []const u8,
    a_title: []const u8,
    b_harness: []const u8,
    b_id: []const u8,
    b_title: []const u8,
    kind: []const u8, // exact | extended
    extra_messages: usize = 0,
    extended_side: []const u8 = "",
    original_harness: []const u8 = "",
    copy_harness: []const u8 = "",
    confidence: []const u8 = "low",
    reason: []const u8 = "no provenance; earlier timestamp assumed original",
};

pub const Conflict = struct {
    harness: []const u8,
    id: []const u8,
    title: []const u8,
    other_title: []const u8,
    message_counts: []const u8,
};

pub const Result = struct {
    duplicates: []const Duplicate = &.{},
    conflicts: []const Conflict = &.{},
    collapsed: usize = 0,
    merged: usize = 0,
};

/// Comparison fingerprint: ignore Markdown markers, HTML entities, doubled
/// apostrophes from SQL escaping, case and whitespace. The old ai-sync
/// importer escaped quotes by doubling them, which otherwise makes identical
/// chats look like different variants.
fn fingerprint(a: std.mem.Allocator, raw: []const u8) []const u8 {
    var text = std.mem.replaceOwned(u8, a, raw, "&amp;", "&") catch raw;
    text = std.mem.replaceOwned(u8, a, text, "&quot;", "\"") catch text;
    text = std.mem.replaceOwned(u8, a, text, "&#39;", "'") catch text;
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var last_quote = false;
    for (text) |c| {
        if (c == '\'' or c == 0xe2) {
            // Collapse runs of apostrophes (including Unicode right single
            // quote's leading byte) to one; skip the continuation bytes too.
            if (!last_quote) out.append(a, '\'') catch {};
            last_quote = true;
            continue;
        }
        if (last_quote and c >= 0x80 and c <= 0xbf) continue;
        last_quote = false;
        if (std.ascii.isWhitespace(c) or c == '*' or c == '_' or c == '`' or
            c == '#' or c == '~' or c == '[' or c == ']' or c == '(' or c == ')')
        {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) {
            out.append(a, ' ') catch {};
            pending_space = false;
        }
        out.append(a, std.ascii.toLower(c)) catch {};
    }
    return out.toOwnedSlice(a) catch raw;
}

fn seqHash(a: std.mem.Allocator, session: Session) u64 {
    var h = std.hash.Wyhash.init(0);
    for (session.messages) |m| {
        h.update(m.role);
        h.update(fingerprint(a, m.content));
        h.update(m.provider);
        h.update(m.model);
    }
    return h.final();
}

/// Text-only hash for cross-harness comparison: model metadata differs by
/// design between harnesses and must not hide identical transcripts.
fn textHash(a: std.mem.Allocator, session: Session) u64 {
    var h = std.hash.Wyhash.init(0);
    for (session.messages) |m| {
        h.update(m.role);
        h.update(fingerprint(a, m.content));
    }
    return h.final();
}

fn sameText(alloc: std.mem.Allocator, a: model.Message, b: model.Message) bool {
    return std.mem.eql(u8, a.role, b.role) and
        std.mem.eql(u8, fingerprint(alloc, a.content), fingerprint(alloc, b.content));
}

fn containsText(alloc: std.mem.Allocator, sup: []const model.Message, sub: []const model.Message) bool {
    if (sub.len < 4 or sup.len < sub.len) return false;
    var j: usize = 0;
    for (sup) |m| {
        if (j < sub.len and sameText(alloc, m, sub[j])) j += 1;
        if (j == sub.len) return true;
    }
    return false;
}

fn firstHash(a: std.mem.Allocator, session: Session) u64 {
    if (session.messages.len == 0) return 0;
    const m = session.messages[0];
    var h = std.hash.Wyhash.init(0);
    h.update(m.role);
    h.update(fingerprint(a, m.content));
    return h.final();
}

fn sameMessage(alloc: std.mem.Allocator, a: model.Message, b: model.Message) bool {
    return std.mem.eql(u8, a.role, b.role) and std.mem.eql(u8, fingerprint(alloc, a.content), fingerprint(alloc, b.content)) and
        std.mem.eql(u8, a.provider, b.provider) and std.mem.eql(u8, a.model, b.model);
}

/// Same prompts answered by different models: an intentional comparison,
/// not a divergent copy of one session.
fn modelComparison(alloc: std.mem.Allocator, a: Session, b: Session) bool {
    // Same prompts, different answers: most often the same task run through
    // several models. Turn counts can differ, so compare only the user turns.
    var au: usize = 0;
    var bu: usize = 0;
    var has_answer = false;
    for (a.messages) |m| {
        if (std.mem.eql(u8, m.role, "user")) au += 1 else if (std.mem.eql(u8, m.role, "assistant")) has_answer = true;
    }
    for (b.messages) |m| {
        if (std.mem.eql(u8, m.role, "user")) bu += 1 else if (std.mem.eql(u8, m.role, "assistant")) has_answer = true;
    }
    if (au == 0 or au != bu or !has_answer) return false;
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.messages.len and bi < b.messages.len) {
        if (!std.mem.eql(u8, a.messages[ai].role, "user")) {
            ai += 1;
            continue;
        }
        if (!std.mem.eql(u8, b.messages[bi].role, "user")) {
            bi += 1;
            continue;
        }
        if (!std.mem.eql(u8, fingerprint(alloc, a.messages[ai].content), fingerprint(alloc, b.messages[bi].content))) return false;
        ai += 1;
        bi += 1;
    }
    return true;
}

/// Contiguous containment: an export that gained messages keeps the original
/// transcript as a block. This avoids treating every short preamble as a match.
fn contains(alloc: std.mem.Allocator, sup: []const model.Message, sub: []const model.Message) bool {
    if (sub.len == 0 or sup.len < sub.len) return false;
    var i: usize = 0;
    while (i + sub.len <= sup.len) : (i += 1) {
        var ok = true;
        for (sub, 0..) |m, j| {
            if (!sameMessage(alloc, sup[i + j], m)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn userHash(a: std.mem.Allocator, session: Session) u64 {
    var h = std.hash.Wyhash.init(0);
    for (session.messages) |m| {
        if (!std.mem.eql(u8, m.role, "user")) continue;
        h.update(fingerprint(a, m.content));
    }
    return h.final();
}

/// Ordered-subsequence containment for cross-harness comparisons: an import
/// may drop control messages, so the surviving turns stay in order but not
/// necessarily contiguous.
fn containsOrdered(alloc: std.mem.Allocator, sup: []const model.Message, sub: []const model.Message) bool {
    if (sub.len < 4 or sup.len < sub.len) return false;
    var j: usize = 0;
    for (sup) |m| {
        if (j < sub.len and sameMessage(alloc, m, sub[j])) j += 1;
        if (j == sub.len) return true;
    }
    return false;
}

fn better(a: Session, b: Session) bool {
    if (a.messages.len != b.messages.len) return a.messages.len > b.messages.len;
    return a.title.len >= b.title.len;
}

fn mergeGroup(a: std.mem.Allocator, sessions: *std.ArrayList(Session), indices: []const usize, conflicts: *std.ArrayList(Conflict), remove: *std.ArrayList(usize), collapsed: *usize, merged: *usize) !void {
    if (indices.len < 2) return;
    var best = indices[0];
    for (indices[1..]) |idx| {
        if (better(sessions.items[idx], sessions.items[best])) best = idx;
    }
    for (indices) |idx| {
        if (idx == best) continue;
        const a_s = sessions.items[best];
        const b_s = sessions.items[idx];
        if (seqHash(a, a_s) == seqHash(a, b_s)) {
            collapsed.* += 1;
            try remove.append(a, idx);
        } else if (contains(a, a_s.messages, b_s.messages)) {
            merged.* += 1;
            try remove.append(a, idx);
        } else if (contains(a, b_s.messages, a_s.messages)) {
            merged.* += 1;
            const old_best = best;
            best = idx;
            try remove.append(a, old_best);
        } else if (!modelComparison(a, a_s, b_s)) {
            try conflicts.append(a, .{
                .harness = a_s.harness,
                .id = a_s.id,
                .title = a_s.title,
                .other_title = b_s.title,
                .message_counts = try std.fmt.allocPrint(a, "{d} vs {d}", .{ a_s.messages.len, b_s.messages.len }),
            });
        }
    }
}

fn removeIndices(a: std.mem.Allocator, sessions: *std.ArrayList(Session), remove: *std.ArrayList(usize)) void {
    _ = a;
    std.mem.sort(usize, remove.items, {}, comptime std.sort.desc(usize));
    for (remove.items) |idx| {
        if (idx < sessions.items.len) _ = sessions.orderedRemove(idx);
    }
    remove.clearRetainingCapacity();
}

pub fn process(a: std.mem.Allocator, sessions: *std.ArrayList(Session)) !Result {
    var conflicts: std.ArrayList(Conflict) = .empty;
    var remove: std.ArrayList(usize) = .empty;
    var collapsed: usize = 0;
    var merged: usize = 0;

    // Pass 1: same harness and same session id.
    var groups = std.StringHashMap(std.ArrayList(usize)).init(a);
    for (sessions.items, 0..) |s, i| {
        const usable_id = s.id.len > 0 and std.mem.indexOfScalar(u8, s.id, ' ') == null;
        const key = if (usable_id)
            try std.fmt.allocPrint(a, "{s}\x1f{s}", .{ s.harness, s.id })
        else
            try std.fmt.allocPrint(a, "{s}\x1fhash-{d}", .{ s.harness, firstHash(a, s) });
        const gop = try groups.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, i);
    }
    var it = groups.iterator();
    while (it.next()) |entry| try mergeGroup(a, sessions, entry.value_ptr.items, &conflicts, &remove, &collapsed, &merged);
    removeIndices(a, sessions, &remove);

    // Pass 2: repeated tasks often get a fresh session id but keep the same
    // title and opening prompt (e.g. "Reply with the single word: PONG").
    // Collapse those within the harness as well; divergent copies are kept
    // and reported as conflicts.
    var by_task = std.StringHashMap(std.ArrayList(usize)).init(a);
    for (sessions.items, 0..) |s, i| {
        const key = try std.fmt.allocPrint(a, "{s}\x1f{s}\x1f{d}", .{ s.harness, s.title, firstHash(a, s) });
        const gop = try by_task.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, i);
    }
    var tit = by_task.iterator();
    while (tit.next()) |entry| try mergeGroup(a, sessions, entry.value_ptr.items, &conflicts, &remove, &collapsed, &merged);
    removeIndices(a, sessions, &remove);

    // Cross-harness duplicates are reported, never merged.
    var buckets = std.AutoHashMap(u64, std.ArrayList(usize)).init(a);
    for (sessions.items, 0..) |s, i| {
        const gop = try buckets.getOrPut(userHash(a, s));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, i);
    }
    var duplicates: std.ArrayList(Duplicate) = .empty;
    var bit = buckets.iterator();
    while (bit.next()) |entry| {
        const idxs = entry.value_ptr.items;
        if (idxs.len < 2) continue;
        for (idxs, 0..) |i, x| {
            for (idxs[x + 1 ..]) |j| {
                const s1 = sessions.items[i];
                const s2 = sessions.items[j];
                if (s1.messages.len < 4 or s2.messages.len < 4) continue;
                if (std.mem.eql(u8, s1.harness, s2.harness)) continue;
                const h1 = textHash(a, s1);
                const h2 = textHash(a, s2);
                var kind: []const u8 = "";
                var extra: usize = 0;
                var side: []const u8 = "";
                if (h1 == h2) {
                    kind = "exact";
                } else if (containsText(a, s1.messages, s2.messages)) {
                    kind = "extended";
                    extra = s1.messages.len - s2.messages.len;
                    side = s1.harness;
                } else if (containsText(a, s2.messages, s1.messages)) {
                    kind = "extended";
                    extra = s2.messages.len - s1.messages.len;
                    side = s2.harness;
                } else {
                    // Same prompts, different answers/metadata: still a
                    // cross-harness copy, but not an exact message sequence.
                    kind = if (s1.messages.len == s2.messages.len) "variant" else "extended";
                    if (s1.messages.len > s2.messages.len) {
                        extra = s1.messages.len - s2.messages.len;
                        side = s1.harness;
                    } else if (s2.messages.len > s1.messages.len) {
                        extra = s2.messages.len - s1.messages.len;
                        side = s2.harness;
                    }
                }
                var original = s1.harness;
                var copy = s2.harness;
                var confidence: []const u8 = "low";
                var reason: []const u8 = "no provenance; earlier timestamp assumed original";
                const ha = s1.harness;
                const hb = s2.harness;
                if ((std.mem.eql(u8, ha, "typingmind") and std.mem.eql(u8, hb, "anythingllm")) or
                    (std.mem.eql(u8, hb, "typingmind") and std.mem.eql(u8, ha, "anythingllm")))
                {
                    original = "typingmind";
                    copy = "anythingllm";
                    confidence = "high";
                    reason = "Dorothy ai-sync imported TypingMind exports into AnythingLLM workspaces";
                } else if ((std.mem.eql(u8, ha, "chatgpt") and std.mem.eql(u8, hb, "typingmind")) or
                    (std.mem.eql(u8, hb, "chatgpt") and std.mem.eql(u8, ha, "typingmind")))
                {
                    original = "chatgpt";
                    copy = "typingmind";
                    confidence = "high";
                    reason = "ChatGPT export was imported into TypingMind; treat bogus 1970 TypingMind timestamps as non-evidence";
                } else if ((std.mem.eql(u8, ha, "chatgpt") and std.mem.eql(u8, hb, "anythingllm")) or
                    (std.mem.eql(u8, hb, "chatgpt") and std.mem.eql(u8, ha, "anythingllm")))
                {
                    original = "chatgpt";
                    copy = "anythingllm";
                    confidence = "high";
                    reason = "ChatGPT to TypingMind to AnythingLLM import chain";
                } else if (std.mem.order(u8, s1.stamp, s2.stamp) == .gt) {
                    original = s2.harness;
                    copy = s1.harness;
                }
                try duplicates.append(a, .{
                    .a_harness = s1.harness,
                    .a_id = s1.id,
                    .a_title = s1.title,
                    .b_harness = s2.harness,
                    .b_id = s2.id,
                    .b_title = s2.title,
                    .kind = kind,
                    .extra_messages = extra,
                    .extended_side = side,
                    .original_harness = original,
                    .copy_harness = copy,
                    .confidence = confidence,
                    .reason = reason,
                });
            }
        }
    }

    return .{
        .duplicates = try duplicates.toOwnedSlice(a),
        .conflicts = try conflicts.toOwnedSlice(a),
        .collapsed = collapsed,
        .merged = merged,
    };
}

fn put(a: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try obj.put(a, key, .{ .string = value });
}

fn writeJson(a: std.mem.Allocator, io: std.Io, path: []const u8, value: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn writeReports(a: std.mem.Allocator, io: std.Io, output: []const u8, result: Result) !void {
    var dup_root = std.json.ObjectMap.empty;
    try dup_root.put(a, "count", .{ .integer = @intCast(result.duplicates.len) });
    var dups = std.json.Array.init(a);
    for (result.duplicates) |d| {
        var item = std.json.ObjectMap.empty;
        try put(a, &item, "harness_a", d.a_harness);
        try put(a, &item, "id_a", d.a_id);
        try put(a, &item, "title_a", d.a_title);
        try put(a, &item, "harness_b", d.b_harness);
        try put(a, &item, "id_b", d.b_id);
        try put(a, &item, "title_b", d.b_title);
        try put(a, &item, "kind", d.kind);
        try put(a, &item, "extended_side", d.extended_side);
        try put(a, &item, "original_harness", d.original_harness);
        try put(a, &item, "copy_harness", d.copy_harness);
        try put(a, &item, "confidence", d.confidence);
        try put(a, &item, "reason", d.reason);
        try item.put(a, "extra_messages", .{ .integer = @intCast(d.extra_messages) });
        try dups.append(.{ .object = item });
    }
    try dup_root.put(a, "duplicates", .{ .array = dups });
    try writeJson(a, io, try std.fs.path.join(a, &.{ output, "duplicates.json" }), .{ .object = dup_root });

    var con_root = std.json.ObjectMap.empty;
    try con_root.put(a, "count", .{ .integer = @intCast(result.conflicts.len) });
    var cons = std.json.Array.init(a);
    for (result.conflicts) |c| {
        var item = std.json.ObjectMap.empty;
        try put(a, &item, "harness", c.harness);
        try put(a, &item, "id", c.id);
        try put(a, &item, "title", c.title);
        try put(a, &item, "other_title", c.other_title);
        try put(a, &item, "message_counts", c.message_counts);
        try cons.append(.{ .object = item });
    }
    try con_root.put(a, "conflicts", .{ .array = cons });
    try writeJson(a, io, try std.fs.path.join(a, &.{ output, "conflicts.json" }), .{ .object = con_root });
}
