const std = @import("std");
const zls = @import("zls");

const Context = @import("../context.zig").Context;

const types = zls.lsp.types;

const allocator: std.mem.Allocator = std.testing.allocator;

const Document = struct {
    path: []const u8,
    source: []const u8,
};

const project: []const Document = &.{
    .{
        .path = "/project/src/main.zig",
        .source =
        \\const std = @import("std");
        \\const TriangleMesh = @import("TriangleMesh.zig");
        \\const gfx = @import("./gfx/main.zig");
        \\const config = @import("config.zon");
        \\
        ,
    },
    .{
        .path = "/project/src/TriangleMesh.zig",
        .source =
        \\const main = @import("main.zig");
        \\const shader = @embedFile("gfx/shader.wgsl");
        \\
        ,
    },
    .{
        .path = "/project/src/gfx/main.zig",
        .source =
        \\const TriangleMesh = @import("../TriangleMesh.zig");
        \\const root = @import("../main.zig");
        \\
        ,
    },
};

test "willRenameFiles - rename file" {
    try testWillRename(&.{.{ "/project/src/TriangleMesh.zig", "/project/src/Renderer.zig" }}, &.{
        .{
            .path = "/project/src/main.zig",
            .source =
            \\const std = @import("std");
            \\const TriangleMesh = @import("Renderer.zig");
            \\const gfx = @import("./gfx/main.zig");
            \\const config = @import("config.zon");
            \\
            ,
        },
        project[1],
        .{
            .path = "/project/src/gfx/main.zig",
            .source =
            \\const TriangleMesh = @import("../Renderer.zig");
            \\const root = @import("../main.zig");
            \\
            ,
        },
    });
}

test "willRenameFiles - move file into another directory" {
    try testWillRename(&.{.{ "/project/src/TriangleMesh.zig", "/project/src/gfx/Renderer.zig" }}, &.{
        .{
            .path = "/project/src/main.zig",
            .source =
            \\const std = @import("std");
            \\const TriangleMesh = @import("gfx/Renderer.zig");
            \\const gfx = @import("./gfx/main.zig");
            \\const config = @import("config.zon");
            \\
            ,
        },
        .{
            .path = "/project/src/TriangleMesh.zig",
            .source =
            \\const main = @import("../main.zig");
            \\const shader = @embedFile("shader.wgsl");
            \\
            ,
        },
        .{
            .path = "/project/src/gfx/main.zig",
            .source =
            \\const TriangleMesh = @import("Renderer.zig");
            \\const root = @import("../main.zig");
            \\
            ,
        },
    });
}

test "willRenameFiles - rename directory" {
    try testWillRename(&.{.{ "/project/src/gfx", "/project/src/render" }}, &.{
        .{
            .path = "/project/src/main.zig",
            .source =
            \\const std = @import("std");
            \\const TriangleMesh = @import("TriangleMesh.zig");
            \\const gfx = @import("./render/main.zig");
            \\const config = @import("config.zon");
            \\
            ,
        },
        .{
            .path = "/project/src/TriangleMesh.zig",
            .source =
            \\const main = @import("main.zig");
            \\const shader = @embedFile("render/shader.wgsl");
            \\
            ,
        },
        project[2],
    });
}

test "willRenameFiles - unrelated file" {
    try testWillRename(&.{.{ "/project/src/other.zig", "/project/src/other2.zig" }}, project);
}

test "rename @import path" {
    var ctx: Context = try .init();
    defer ctx.deinit();
    const arena = ctx.arena.allocator();
    try openProject(&ctx, project);

    const main_uri = try uriFromPath(arena, project[0].path);
    const main_source = project[0].source;
    const index = std.mem.find(u8, main_source, "TriangleMesh.zig").? + 3;
    const position = zls.offsets.indexToPosition(main_source, index, ctx.server.offset_encoding);

    // prepareRename returns the import path without quotes
    const prepare = try ctx.server.sendRequestSync(arena, "textDocument/prepareRename", .{
        .textDocument = .{ .uri = main_uri },
        .position = position,
    }) orelse return error.InvalidResponse;
    try std.testing.expectEqualStrings("TriangleMesh.zig", prepare.prepare_rename_placeholder.placeholder);

    // the file extension is added automatically
    const edit = try ctx.server.sendRequestSync(arena, "textDocument/rename", .{
        .textDocument = .{ .uri = main_uri },
        .position = position,
        .newName = "Renderer",
    }) orelse return error.InvalidResponse;

    const document_changes = edit.documentChanges.?;
    try std.testing.expectEqual(@as(usize, 3), document_changes.len);

    var results: std.ArrayList(Document) = .empty;
    for (document_changes[0..2]) |change| {
        const text_document_edit = change.text_document_edit;
        const path = (try zls.Uri.parse(arena, text_document_edit.textDocument.uri)).toStdUri().path.percent_encoded;
        const original = for (project) |document| {
            if (std.mem.eql(u8, document.path, path)) break document;
        } else return error.UnexpectedDocument;
        var edits: std.ArrayList(types.TextEdit) = .empty;
        for (text_document_edit.edits) |e| try edits.append(arena, e.text_edit);
        const new_source = try zls.diff.applyTextEdits(arena, original.source, edits.items, ctx.server.offset_encoding);
        try results.append(arena, .{ .path = path, .source = new_source });
    }
    std.mem.sort(Document, results.items, {}, documentLessThan);
    try std.testing.expectEqualStrings("/project/src/gfx/main.zig", results.items[0].path);
    try zls.testing.expectEqualStrings(
        \\const TriangleMesh = @import("../Renderer.zig");
        \\const root = @import("../main.zig");
        \\
    , results.items[0].source);
    try std.testing.expectEqualStrings("/project/src/main.zig", results.items[1].path);
    try zls.testing.expectEqualStrings(
        \\const std = @import("std");
        \\const TriangleMesh = @import("Renderer.zig");
        \\const gfx = @import("./gfx/main.zig");
        \\const config = @import("config.zon");
        \\
    , results.items[1].source);

    const rename_file = document_changes[2].rename_file;
    try std.testing.expectEqualStrings("file:///project/src/TriangleMesh.zig", rename_file.oldUri);
    try std.testing.expectEqualStrings("file:///project/src/Renderer.zig", rename_file.newUri);
}

test "rename - non file @import is a normal rename" {
    var ctx: Context = try .init();
    defer ctx.deinit();
    const arena = ctx.arena.allocator();
    try openProject(&ctx, project);

    const main_uri = try uriFromPath(arena, project[0].path);
    const index = std.mem.find(u8, project[0].source, "\"std\"").? + 2;
    const position = zls.offsets.indexToPosition(project[0].source, index, ctx.server.offset_encoding);

    const edit = try ctx.server.sendRequestSync(arena, "textDocument/rename", .{
        .textDocument = .{ .uri = main_uri },
        .position = position,
        .newName = "foo",
    });
    if (edit) |e| try std.testing.expect(e.documentChanges == null);
}

fn documentLessThan(_: void, a: Document, b: Document) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn uriFromPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.mem.concat(arena, u8, &.{ "file://", path });
}

fn openProject(ctx: *Context, documents: []const Document) !void {
    const arena = ctx.arena.allocator();
    for (documents) |document| {
        try ctx.server.sendNotificationSync(arena, "textDocument/didOpen", .{
            .textDocument = .{
                .uri = try uriFromPath(arena, document.path),
                .languageId = .{ .custom_value = "zig" },
                .version = 1,
                .text = document.source,
            },
        });
    }
}

fn testWillRename(renames: []const struct { []const u8, []const u8 }, expected: []const Document) !void {
    var ctx: Context = try .init();
    defer ctx.deinit();
    const arena = ctx.arena.allocator();
    try openProject(&ctx, project);

    const files = try arena.alloc(types.workspace.FileRename, renames.len);
    for (files, renames) |*file, rename| {
        file.* = .{
            .oldUri = try uriFromPath(arena, rename[0]),
            .newUri = try uriFromPath(arena, rename[1]),
        };
    }

    const response = try ctx.server.sendRequestSync(arena, "workspace/willRenameFiles", .{ .files = files });

    for (project, expected) |document, expected_document| {
        const uri = try uriFromPath(arena, document.path);
        const edits: []const types.TextEdit = if (response) |edit| edit.changes.?.map.get(uri) orelse &.{} else &.{};
        const actual = try zls.diff.applyTextEdits(arena, document.source, edits, ctx.server.offset_encoding);
        try zls.testing.expectEqualStrings(expected_document.source, actual);
    }
}
