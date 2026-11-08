//! Renaming and moving files while keeping `@import` / `@embedFile` paths up to date.
//!
//! - [`workspace/willRenameFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_willRenameFiles):
//!   the client renames a file or folder (e.g. in the file explorer) and ZLS updates all imports.
//! - `textDocument/rename` on the string of an `@import("file.zig")`: works like renaming a
//!   variable. The file is renamed and all imports that refer to it are updated.

const std = @import("std");
const Ast = std.zig.Ast;

const lsp = @import("lsp");
const types = lsp.types;
const DocumentStore = @import("../DocumentStore.zig");
const Server = @import("../Server.zig");
const Uri = @import("../Uri.zig");
const offsets = @import("../offsets.zig");
const tracy = @import("tracy");

const log = std.log.scoped(.file_rename);

pub const Error = error{ OutOfMemory, Canceled, InvalidParams };

/// A file or folder rename. Paths are the percent decoded paths of `file://` URIs.
const Rename = struct {
    old_path: []const u8,
    new_path: []const u8,

    /// Returns the path after the rename or `null` if `path` is not affected.
    fn apply(rename: Rename, arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
        if (std.mem.eql(u8, path, rename.old_path)) return rename.new_path;
        if (path.len > rename.old_path.len and
            std.mem.startsWith(u8, path, rename.old_path) and
            path[rename.old_path.len] == '/')
        {
            return try std.mem.concat(arena, u8, &.{ rename.new_path, path[rename.old_path.len..] });
        }
        return null;
    }
};

pub const file_operation_filters: []const types.workspace.file_operation.Filter = &.{
    .{ .scheme = "file", .pattern = .{ .glob = "**/*.{zig,zon}", .matches = .file } },
    .{ .scheme = "file", .pattern = .{ .glob = "**", .matches = .folder } },
};

pub fn @"workspace/willRenameFiles"(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.workspace.RenameFilesParams,
) Error!?types.WorkspaceEdit {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var renames: std.ArrayList(Rename) = .empty;
    for (request.files) |file| {
        const old_uri = Uri.parse(arena, file.oldUri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidParams,
        };
        const new_uri = Uri.parse(arena, file.newUri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidParams,
        };
        if (!isSupportedScheme(old_uri) or !isSupportedScheme(new_uri)) continue;
        try renames.append(arena, .{
            .old_path = try uriPath(arena, old_uri),
            .new_path = try uriPath(arena, new_uri),
        });
    }
    if (renames.items.len == 0) return null;

    const changes = try collectImportEdits(server, arena, renames.items);
    if (changes.count() == 0) return null;

    var workspace_edit: types.WorkspaceEdit = .{ .changes = .{} };
    try workspace_edit.changes.?.map.ensureTotalCapacity(arena, changes.count());
    for (changes.keys(), changes.values()) |uri, edits| {
        workspace_edit.changes.?.map.putAssumeCapacityNoClobber(uri, edits.items);
    }
    return workspace_edit;
}

/// Returns the location of the import path (without quotes) if `source_index` is
/// inside the string literal of an `@import` or `@embedFile` that refers to a file.
pub fn importPathLocAtIndex(tree: *const Ast, source_index: usize) ?struct { offsets.Loc, Ast.TokenIndex } {
    const token = offsets.sourceIndexToTokenIndex(tree, source_index).pickTokenTag(.string_literal, tree) orelse return null;
    if (tree.tokenTag(token) != .string_literal) return null;
    if (token < 2 or tree.tokenTag(token - 1) != .l_paren or tree.tokenTag(token - 2) != .builtin) return null;
    const builtin = offsets.tokenToSlice(tree, token - 2);
    if (!std.mem.eql(u8, builtin, "@import") and !std.mem.eql(u8, builtin, "@embedFile")) return null;
    const loc = offsets.tokenToLoc(tree, token);
    const path = tree.source[loc.start + 1 .. loc.end - 1];
    if (std.mem.eql(u8, builtin, "@import") and !isFileImport(path)) return null;
    return .{ .{ .start = loc.start + 1, .end = loc.end - 1 }, token };
}

/// Handles `textDocument/rename` on the path of an `@import`. The new name is the new import path.
pub fn renameImportedFile(
    server: *Server,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    new_name: []const u8,
) Error!?types.WorkspaceEdit {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    const path_loc, _ = importPathLocAtIndex(tree, source_index) orelse return null;
    const old_import = offsets.locToSlice(tree.source, path_loc);

    var new_import = std.mem.trim(u8, new_name, " \t\"");
    if (new_import.len == 0) return error.InvalidParams;
    if (std.Io.Dir.path.extension(new_import).len == 0) {
        new_import = try std.mem.concat(arena, u8, &.{ new_import, std.Io.Dir.path.extension(old_import) });
    }
    if (std.mem.eql(u8, old_import, new_import)) return null;

    const importer_path = try uriPath(arena, handle.uri);
    const importer_dir = std.Io.Dir.path.dirnamePosix(importer_path) orelse "/";
    const old_path = try std.Io.Dir.path.resolveAllocPosix(arena, &.{ importer_dir, old_import });
    const new_path = try std.Io.Dir.path.resolveAllocPosix(arena, &.{ importer_dir, new_import });

    const parsed_uri = handle.uri.toStdUri();
    const old_uri = try Uri.resolveImport(arena, handle.uri, parsed_uri, old_import);
    const new_uri = try Uri.resolveImport(arena, handle.uri, parsed_uri, new_import);

    const changes = try collectImportEdits(server, arena, &.{.{ .old_path = old_path, .new_path = new_path }});

    const DocumentChange = @typeInfo(@typeInfo(@FieldType(types.WorkspaceEdit, "documentChanges")).optional.child).pointer.child;
    const TextDocumentEditItem = @typeInfo(@FieldType(types.TextDocument.Edit, "edits")).pointer.child;

    var document_changes: std.ArrayList(DocumentChange) = try .initCapacity(arena, changes.count() + 1);
    for (changes.keys(), changes.values()) |uri, edits| {
        const items = try arena.alloc(TextDocumentEditItem, edits.items.len);
        for (items, edits.items) |*item, edit| item.* = .{ .text_edit = edit };
        document_changes.appendAssumeCapacity(.{ .text_document_edit = .{
            .textDocument = .{ .uri = uri, .version = null },
            .edits = items,
        } });
    }
    // text edits refer to the old location of the file, so the rename comes last
    document_changes.appendAssumeCapacity(.{ .rename_file = .{
        .oldUri = old_uri.raw,
        .newUri = new_uri.raw,
    } });

    return .{ .documentChanges = document_changes.items };
}

/// Returns a map from document URIs to the text edits that update the import paths.
fn collectImportEdits(
    server: *Server,
    arena: std.mem.Allocator,
    renames: []const Rename,
) Error!std.array_hash_map.String(std.ArrayList(types.TextEdit)) {
    const store = &server.document_store;

    // make sure that all files in the workspace are known
    for (server.workspaces.items) |workspace| {
        _ = store.loadDirectoryRecursive(workspace.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.UnsupportedScheme => {},
            else => log.warn("failed to load workspace '{s}': {}", .{ workspace.uri.raw, err }),
        };
    }

    var changes: std.array_hash_map.String(std.ArrayList(types.TextEdit)) = .empty;

    var it: DocumentStore.HandleIterator = .{ .store = store };
    while (it.next()) |handle| {
        if (!isSupportedScheme(handle.uri)) continue;
        if (DocumentStore.isInStd(handle.uri)) continue;
        if (handle.tree.mode != .zig) continue;

        const tree = &handle.tree;
        const importer_path = try uriPath(arena, handle.uri);
        const importer_new_path = try applyRenames(arena, renames, importer_path) orelse importer_path;
        const importer_dir = std.Io.Dir.path.dirnamePosix(importer_path) orelse "/";
        const importer_new_dir = std.Io.Dir.path.dirnamePosix(importer_new_path) orelse "/";

        for (tree.tokens.items(.tag), 0..) |tag, i| {
            if (tag != .string_literal) continue;
            const path_loc, const token = importPathLocAtIndex(tree, tree.tokenStart(@intCast(i)) + 1) orelse continue;
            std.debug.assert(token == i);
            const import_path = offsets.locToSlice(tree.source, path_loc);
            if (std.mem.findScalar(u8, import_path, '\\') != null) continue; // escape sequences

            const target_path = try std.Io.Dir.path.resolveAllocPosix(arena, &.{ importer_dir, import_path });
            const target_new_path = try applyRenames(arena, renames, target_path) orelse target_path;
            if (std.mem.eql(u8, importer_path, importer_new_path) and std.mem.eql(u8, target_path, target_new_path)) continue;

            const relative = try std.Io.Dir.path.relativeAllocPosix(arena, "/", importer_new_dir, target_new_path);
            const new_import = if (std.mem.startsWith(u8, import_path, "./") and !std.mem.startsWith(u8, relative, "../"))
                try std.mem.concat(arena, u8, &.{ "./", relative })
            else
                relative;
            if (std.mem.eql(u8, new_import, import_path)) continue;

            const gop = try changes.getOrPutValue(arena, handle.uri.raw, .empty);
            try gop.value_ptr.append(arena, .{
                .range = offsets.locToRange(tree.source, path_loc, server.offset_encoding),
                .newText = new_import,
            });
        }
    }

    return changes;
}

fn applyRenames(arena: std.mem.Allocator, renames: []const Rename, path: []const u8) error{OutOfMemory}!?[]const u8 {
    for (renames) |rename| {
        if (try rename.apply(arena, path)) |new_path| return new_path;
    }
    return null;
}

fn isSupportedScheme(uri: Uri) bool {
    const scheme = uri.toStdUri().scheme;
    return std.mem.eql(u8, scheme, "file") or std.mem.eql(u8, scheme, "untitled");
}

fn isFileImport(import_path: []const u8) bool {
    return std.mem.endsWith(u8, import_path, ".zig") or std.mem.endsWith(u8, import_path, ".zon");
}

/// Returns the percent decoded path component of the URI.
fn uriPath(arena: std.mem.Allocator, uri: Uri) error{OutOfMemory}![]const u8 {
    const path = try uri.toStdUri().path.toRawMaybeAlloc(arena);
    return std.mem.trimEnd(u8, path, "/");
}
