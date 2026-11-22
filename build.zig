// Unless explicitly acquired and licensed from Licensor under another
// license, the contents of this file are subject to the Reciprocal Public
// License ("RPL") Version 1.5, or subsequent versions as allowed by the RPL,
// and You may not copy or use this file in either source code or executable
// form, except in compliance with the terms and conditions of the RPL.
//
// All software distributed under the RPL is provided strictly on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND. See LICENSE.md (RPL-1.5).

const std = @import("std");

const targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
    .{ .name = "windows-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
};

fn readVersionFromZon(b: *std.Build) []const u8 {
    const a = b.allocator;
    const text = b.root.root_dir.handle.readFileAlloc(b.graph.io, "build.zig.zon", a, .limited(4096)) catch return "0.0.0";
    defer a.free(text);
    const key = ".version = \"";
    const start = std.mem.indexOf(u8, text, key) orelse return "0.0.0";
    const rest = text[start + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.0.0";
    return a.dupe(u8, rest[0..end]) catch return "0.0.0";
}

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .small;
    const native_target = b.standardTargetOptions(.{});
    const version = readVersionFromZon(b);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const native_exe = b.addExecutable(.{
        .name = "ai-export-sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = native_target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    native_exe.root_module.addImport("build_options", build_options.createModule());
    b.installArtifact(native_exe);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/normalize.test.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("build_options", build_options.createModule());
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);

    const dist = b.step("dist", "cross-compile release binaries");
    for (targets) |t| {
        const exe = b.addExecutable(.{
            .name = "ai-export-sync",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = optimize,
                .strip = true,
            }),
        });
        exe.root_module.addImport("build_options", build_options.createModule());
        const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = t.name } } });
        dist.dependOn(&install.step);
    }
}
