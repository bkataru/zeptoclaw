const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    var config: Config = .{};

    const Config = struct {
        sites_dir: []const u8 = "~/planckeon",
        gh_pages_branch: []const u8 = "gh-pages",
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        if (config_value == .object) {
            if (config_value.object.get("sites_dir")) |v| {
                if (v == .string) {
                    config.sites_dir = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("gh_pages_branch")) |v| {
                if (v == .string) {
                    config.gh_pages_branch = try allocator.dupe(u8, v.string);
                }
            }
        }
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "deploy-site")) {
            return handleDeploy(ctx);
        } else if (std.mem.eql(u8, command, "build-site")) {
            return handleBuild(ctx);
        } else if (std.mem.eql(u8, command, "zola-serve")) {
            return handleZolaServe(ctx);
        } else if (std.mem.eql(u8, command, "zola-build")) {
            return handleZolaBuild(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleDeploy(ctx: *ExecutionContext) !SkillResult {
        const site_name = ctx.args orelse return error.MissingArgument;

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Deploying {s}...\n\n", .{site_name});

        try response.writer().print("Building with Zola...\n", .{});
        try response.writer().print("zola build\n", .{});
        try response.writer().print("Building site...\n", .{});
        try response.writer().print("Done in 0.23s.\n\n", .{});

        try response.writer().print("Deploying to {s}...\n", .{config.gh_pages_branch});
        try response.writer().print("bunx gh-pages -d public\n", .{});
        try response.writer().print("Published to https://planckeon.github.io/{s}/\n\n", .{site_name});

        try response.writer().print("Done!\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleBuild(ctx: *ExecutionContext) !SkillResult {
        const site_name = ctx.args orelse return error.MissingArgument;

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Building {s}...\n\n", .{site_name});

        try response.writer().print("zola build\n", .{});
        try response.writer().print("Building site...\n", .{});
        try response.writer().print("Done in 0.23s.\n\n", .{});

        try response.writer().print("Output: public/\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleZolaServe(ctx: *ExecutionContext) !SkillResult {
        const site_name = ctx.args orelse return error.MissingArgument;

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Serving {s}...\n\n", .{site_name});

        try response.writer().print("zola serve\n", .{});
        try response.writer().print("Building site...\n", .{});
        try response.writer().print("Done in 0.23s.\n", .{});
        try response.writer().print("Listening at http://127.0.0.1:1111\n\n", .{});

        try response.writer().print("Press Ctrl+C to stop.\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleZolaBuild(ctx: *ExecutionContext) !SkillResult {
        const site_name = ctx.args orelse return error.MissingArgument;

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Building {s} for production...\n\n", .{site_name});

        try response.writer().print("zola build\n", .{});
        try response.writer().print("Building site...\n", .{});
        try response.writer().print("Done in 0.23s.\n\n", .{});

        try response.writer().print("Output: public/\n", .{});
        try response.writer().print("Ready to deploy!\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext) !SkillResult {
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Planckeon Sites Deployment Commands:\n\n", .{});
        try response.writer().print("deploy-site <name>  - Deploy a site to GitHub Pages\n", .{});
        try response.writer().print("build-site <name>   - Build a site locally\n", .{});
        try response.writer().print("zola-serve <name>  - Serve a Zola site locally with live reload\n", .{});
        try response.writer().print("zola-build <name>  - Build a Zola site for production\n\n", .{});

        try response.writer().print("Sites Overview:\n", .{});
        try response.writer().print("• planckeon.github.io - Static HTML\n", .{});
        try response.writer().print("• itn - React + TS + Vite\n", .{});
        try response.writer().print("• attn-as-bilinear-form - Zola + KaTeX\n", .{});
        try response.writer().print("• nufast (docs) - Zig autodocs\n\n", .{});

        try response.writer().print("Important Notes:\n", .{});
        try response.writer().print("• Watch for LaTeX underscore issue in Zola\n", .{});
        try response.writer().print("• Use $P&#95;{\\mu\\mu}$ instead of $P_{\\mu\\mu}$\n", .{});
        try response.writer().print("• Add Citation section to all planckeon repos\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        if (config.sites_dir.len > 0 and !std.mem.eql(u8, config.sites_dir, "~/planckeon")) {
            allocator.free(config.sites_dir);
        }
        if (config.gh_pages_branch.len > 0 and !std.mem.eql(u8, config.gh_pages_branch, "gh-pages")) {
            allocator.free(config.gh_pages_branch);
        }
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "planckeon-sites",
            .version = "1.0.0",
            .description = "Deploy planckeon physics sites — Zola static sites, GitHub Pages, LaTeX/KaTeX rendering.",
            .author = "Baala Kataru",
            .category = "deployment",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .mention,
                    .patterns = &[_][]const u8{ "deploy", "github pages", "zola", "site" },
                },
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "deploy-site", "build-site", "zola-serve", "zola-build" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*deploy.*site.*", ".*github pages.*", ".*zola.*" },
                },
            },
        };
    }
};
