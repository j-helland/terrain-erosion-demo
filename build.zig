const std = @import("std");

const content_dir = "assets/";
const shader_dir = "shaders/";

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const opts = Options{
        // Standard target options allows the person running `zig build` to choose
        // what target to build for. Here we do not override the defaults, which
        // means any target is allowed, and the default is native. Other options
        // for restricting supported target set are available.
        .target = b.standardTargetOptions(.{}),

        // Standard optimization options allow the person running `zig build` to select
        // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
        // set a preferred release mode, allowing the user to decide how to optimize.
        .optimize = b.standardOptimizeOption(.{}),
    };

    const exe = b.addExecutable(.{
        .name = "app",
        .root_source_file = b.path("src/app.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    // This links our 3rdparty libraries to the executable.
    addDependencies(b, opts, exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests should be a separate executable. This way, the compiler can prune tests from the release build.
    createTestExecutable(b, opts);
}

fn addDependencies(b: *std.Build, opts: Options, exe: *std.Build.Step.Compile) void {
    @import("system_sdk").addLibraryPathsTo(exe);

    // GLFW
    const zglfw = b.dependency("zglfw", .{
        .target = opts.target,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    // OpenGL
    const zopengl = b.dependency("zopengl", .{
        .target = opts.target,
    });
    exe.root_module.addImport("zopengl", zopengl.module("root"));

    // Vector / matrix math.
    const zmath = b.dependency("zmath", .{
        .target = opts.target,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    // DearImgui
    const zgui = b.dependency("zgui", .{
        .target = opts.target,
        .backend = .glfw_opengl3,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

    // assets
    exe_options.addOption([]const u8, "content_dir", content_dir);
    {
        const content_path = b.pathJoin(&.{content_dir});
        const install_content_step = b.addInstallDirectory(.{
            .source_dir = b.path(content_path),
            .install_dir = .{ .custom = "" },
            .install_subdir = b.pathJoin(&.{ "bin", content_dir }),
        });
        exe.step.dependOn(&install_content_step.step);
    }

    // GLSL shader source files
    exe_options.addOption([]const u8, "shader_dir", shader_dir);
    {
        const shader_path = b.pathJoin(&.{ "src", shader_dir });
        const install_shaders_step = b.addInstallDirectory(.{
            .source_dir = b.path(shader_path),
            .install_dir = .{ .custom = "" },
            .install_subdir = b.pathJoin(&.{ "bin", shader_dir }),
        });
        exe.step.dependOn(&install_shaders_step.step);
    }
}

fn createTestExecutable(b: *std.Build, opts: Options) void {
    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    addDependencies(b, opts, exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
