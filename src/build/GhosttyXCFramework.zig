const GhosttyXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const LipoStep = @import("LipoStep.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

xcframework: *XCFrameworkStep,
target: Target,

pub const Target = enum { native, universal };

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // Universal macOS build
    const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);

    // Native macOS build
    const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    // iOS
    const ios = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = null,
        }),
    ));

    // iOS Simulator (arm64)
    const ios_sim_arm64 = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = .simulator,

            // We force the Apple CPU model because the simulator
            // doesn't support the generic CPU model as of Zig 0.14 due
            // to missing "altnzcv" instructions, which is false. This
            // surely can't be right but we can fix this if/when we get
            // back to running simulator builds.
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
        }),
    ));

    // iOS Simulator (x86_64) — needed for Intel Macs
    const ios_sim_x86_64 = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = .simulator,
        }),
    ));

    // Universal iOS Simulator (arm64 + x86_64)
    const ios_sim_universal = LipoStep.create(b, .{
        .name = "ghostty-ios-sim",
        .out_name = "libghostty-fat.a",
        .input_a = ios_sim_arm64.output,
        .input_b = ios_sim_x86_64.output,
    });

    // The xcframework wraps our ghostty library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttyKit",
        .out_path = "macos/GhosttyKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = b.path("include"),
                    .dsym = macos_universal.dsym,
                },
                .{
                    .library = ios.output,
                    .headers = b.path("include"),
                    .dsym = ios.dsym,
                },
                .{
                    .library = ios_sim_universal.output,
                    .headers = b.path("include"),
                    .dsym = null,
                },
            },

            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
                .dsym = macos_native.dsym,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
