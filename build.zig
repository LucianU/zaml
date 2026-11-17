const std = @import("std");

/// Builds the `zaml` CPython extension as a shared library.
///
/// Normally driven by `setup.py`, which passes the Python header and library
/// locations. To build by hand:
///
///   zig build -Doptimize=ReleaseFast -Dpython-include=$(python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const python_include = b.option([]const u8, "python-include", "Directory containing Python.h") orelse
        @panic("missing -Dpython-include=<dir containing Python.h>");
    const python_libdir = b.option([]const u8, "python-libdir", "Directory containing python3.lib (Windows only)");

    const python_h = b.addTranslateC(.{
        .root_source_file = b.path("src/python.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    python_h.addIncludePath(.{ .cwd_relative = python_include });

    // yaml-zig (https://github.com/sakakibara/yaml-zig), pinned in build.zig.zon.
    const yaml_dep = b.dependency("yaml", .{ .target = target, .optimize = optimize });

    const module = b.createModule(.{
        .root_source_file = b.path("src/zaml.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "py", .module = python_h.createModule() },
            .{ .name = "yaml", .module = yaml_dep.module("yaml") },
        },
    });

    if (target.result.os.tag == .windows) {
        // Windows resolves symbols at link time, against the stable-ABI import library.
        const libdir = python_libdir orelse @panic("missing -Dpython-libdir on Windows");
        module.addLibraryPath(.{ .cwd_relative = libdir });
        module.linkSystemLibrary("python3", .{});
    }

    const lib = b.addLibrary(.{
        .name = "zaml",
        .linkage = .dynamic,
        .root_module = module,
    });
    // Python symbols are provided by the interpreter that loads the module.
    lib.linker_allow_shlib_undefined = true;

    b.installArtifact(lib);
}
