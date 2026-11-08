//! Refactoring code actions that operate on a cursor position or selection:
//!
//!   - `refactor.extract`: extract statements (or a `{}` block) into a new function.
//!     Local variables from the enclosing function become typed parameters,
//!     mutated `var`s are passed by pointer and declarations that are used after
//!     the selection are returned (as a tuple if there is more than one).
//!   - `refactor.inline`: inline a local constant into all of its usages.
//!   - `refactor.rewrite`: convert a block with curly braces into an expression,
//!     e.g. `.a => { switch (x) {...} }` -> `.a => switch (x) {...}` or
//!     `blk: { switch (x) { .a => break :blk 1, ... } }` -> `switch (x) { .a => 1, ... }`.
//!   - `refactor.rewrite`: move the type of an initializer into the declaration,
//!     e.g. `var value = T{ ... }` -> `var value: T = .{ ... }`.

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("lsp").types;
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Builder = @import("code_actions.zig").Builder;

pub const Error = Analyser.Error;

pub fn generate(builder: *Builder, range: types.Range) Error!void {
    const tree = &builder.handle.tree;
    if (tree.tokens.len < 2) return;

    const a = offsets.positionToIndex(tree.source, range.start, builder.offset_encoding);
    const b = offsets.positionToIndex(tree.source, range.end, builder.offset_encoding);
    const loc: offsets.Loc = .{ .start = @min(a, b), .end = @max(a, b) };

    const ancestors = try ast.nodesOverlappingIndex(builder.arena, tree, loc.start);

    if (builder.wantKind(.@"refactor.rewrite")) {
        try explicitTypeAnnotation(builder, ancestors, loc.start);
        try blockToExpression(builder, ancestors);
        try assignmentsToExpression(builder, ancestors, loc.start);
    }
    if (builder.wantKind(.@"refactor.inline")) {
        try inlineVariable(builder, loc.start);
    }
    if (builder.wantKind(.@"refactor.extract")) {
        try extractFunction(builder, loc, ancestors);
    }
}

// ---------------------------------------------------------------------------
// `var value = T{}` -> `var value: T = .{}`
// ---------------------------------------------------------------------------

const TypedDeclConversion = struct {
    type_text: []const u8,
    /// Range of the initializer that should be replaced by `replacement`.
    replace_loc: offsets.Loc,
    replacement: []const u8,
    /// The code action is only offered when the cursor is before this source index.
    trigger_end: usize,
};

fn explicitTypeAnnotation(builder: *Builder, ancestors: []const Ast.Node.Index, index: usize) Error!void {
    const tree = &builder.handle.tree;

    const decl_node = for (ancestors) |node| {
        if (tree.fullVarDecl(node) != null) break node;
    } else return;
    const var_decl = tree.fullVarDecl(decl_node).?;
    if (var_decl.ast.type_node != .none) return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    const name_token = var_decl.ast.mut_token + 1;
    if (tree.tokenTag(name_token) != .identifier) return;

    const conversion = try typedDeclConversion(builder, init_node) orelse return;
    if (index > conversion.trigger_end) return;
    if (index < tree.tokenStart(var_decl.firstToken())) return;

    const name_end = offsets.tokenToLoc(tree, name_token).end;
    try builder.actions.append(builder.arena, .{
        .title = try builder.arena.print("move type '{s}' into the declaration", .{conversion.type_text}),
        .kind = .@"refactor.rewrite",
        .isPreferred = false,
        .edit = try builder.createWorkspaceEdit(&.{
            builder.createTextEditPos(name_end, try builder.arena.print(": {s}", .{conversion.type_text})),
            builder.createTextEditLoc(conversion.replace_loc, conversion.replacement),
        }),
    });
}

fn typedDeclConversion(builder: *Builder, init_node: Ast.Node.Index) Error!?TypedDeclConversion {
    const tree = &builder.handle.tree;
    var buffer: [2]Ast.Node.Index = undefined;

    if (tree.fullStructInit(&buffer, init_node)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        return .{
            .type_text = try typeTextWithElemCount(builder, type_expr, struct_init.ast.fields.len),
            .replace_loc = .{ .start = offsets.nodeToLoc(tree, type_expr).start, .end = tree.tokenStart(struct_init.ast.lbrace) },
            .replacement = ".",
            .trigger_end = offsets.tokenToLoc(tree, struct_init.ast.lbrace).end,
        };
    }

    if (tree.fullArrayInit(&buffer, init_node)) |array_init| {
        const type_expr = array_init.ast.type_expr.unwrap() orelse return null;
        return .{
            .type_text = try typeTextWithElemCount(builder, type_expr, array_init.ast.elements.len),
            .replace_loc = .{ .start = offsets.nodeToLoc(tree, type_expr).start, .end = tree.tokenStart(array_init.ast.lbrace) },
            .replacement = ".",
            .trigger_end = offsets.tokenToLoc(tree, array_init.ast.lbrace).end,
        };
    }

    switch (tree.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma => {
            // `@as(T, value)` -> `: T = value`
            if (!std.mem.eql(u8, offsets.tokenToSlice(tree, tree.nodeMainToken(init_node)), "@as")) return null;
            const params = tree.builtinCallParams(&buffer, init_node) orelse return null;
            if (params.len != 2) return null;
            return .{
                .type_text = offsets.nodeToSlice(tree, params[0]),
                .replace_loc = offsets.nodeToLoc(tree, init_node),
                .replacement = offsets.nodeToSlice(tree, params[1]),
                .trigger_end = offsets.nodeToLoc(tree, params[0]).end,
            };
        },
        else => {},
    }

    // decl literals: `T.init(...)`, `try T.init(...)`, `T.value` -> `: T = .init(...)`
    var expr = init_node;
    if (tree.nodeTag(expr) == .@"try") expr = tree.nodeData(expr).node;

    var call_buffer: [1]Ast.Node.Index = undefined;
    const field_access, const trigger_end = if (tree.fullCall(&call_buffer, expr)) |call|
        .{ call.ast.fn_expr, offsets.tokenToLoc(tree, call.ast.lparen).end }
    else
        .{ expr, offsets.nodeToLoc(tree, expr).end };
    if (tree.nodeTag(field_access) != .field_access) return null;
    const lhs, const field_name_token = tree.nodeData(field_access).node_and_token;

    const lhs_type = try builder.analyser.resolveTypeOfNode(.of(lhs, builder.handle)) orelse return null;
    if (!lhs_type.is_type_val) return null;
    const lhs_instance = try lhs_type.instanceTypeVal(builder.analyser) orelse return null;
    const result_type = try builder.analyser.resolveTypeOfNode(.of(init_node, builder.handle)) orelse return null;
    if (!result_type.eql(lhs_instance)) return null;

    return .{
        .type_text = offsets.nodeToSlice(tree, lhs),
        .replace_loc = .{ .start = offsets.nodeToLoc(tree, lhs).start, .end = tree.tokenStart(field_name_token - 1) },
        .replacement = "",
        .trigger_end = trigger_end,
    };
}

/// Returns the source text of `type_expr`. Inferred array lengths (`[_]T`) are replaced with `elem_count`.
fn typeTextWithElemCount(builder: *Builder, type_expr: Ast.Node.Index, elem_count: usize) error{OutOfMemory}![]const u8 {
    const tree = &builder.handle.tree;
    const type_loc = offsets.nodeToLoc(tree, type_expr);
    const array_type = tree.fullArrayType(type_expr) orelse return offsets.locToSlice(tree.source, type_loc);
    const count_node = array_type.ast.elem_count;
    if (tree.nodeTag(count_node) != .identifier or !std.mem.eql(u8, offsets.nodeToSlice(tree, count_node), "_")) {
        return offsets.locToSlice(tree.source, type_loc);
    }
    const count_loc = offsets.nodeToLoc(tree, count_node);
    return try builder.arena.print("{s}{d}{s}", .{
        tree.source[type_loc.start..count_loc.start],
        elem_count,
        tree.source[count_loc.end..type_loc.end],
    });
}

// ---------------------------------------------------------------------------
// inline variable
// ---------------------------------------------------------------------------

fn inlineVariable(builder: *Builder, index: usize) Error!void {
    const tree = &builder.handle.tree;
    const token = offsets.sourceIndexToTokenIndex(tree, index).pickTokenTag(.identifier, tree) orelse return;
    const name = offsets.identifierTokenToNameSlice(tree, token);

    const decl_node: Ast.Node.Index = blk: {
        if (token > 0 and (tree.tokenTag(token - 1) == .keyword_const or tree.tokenTag(token - 1) == .keyword_var)) {
            // cursor is on the name of the declaration
            const ancestors = try ast.nodesOverlappingIndex(builder.arena, tree, tree.tokenStart(token));
            for (ancestors) |node| {
                const var_decl = tree.fullVarDecl(node) orelse continue;
                if (var_decl.ast.mut_token + 1 == token) break :blk node;
            }
            return;
        }
        const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(token)) orelse return;
        if (decl.handle != builder.handle) return;
        if (decl.decl != .ast_node) return;
        break :blk decl.decl.ast_node;
    };

    const var_decl = tree.fullVarDecl(decl_node) orelse return;
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return;
    if (var_decl.comptime_token != null or var_decl.extern_export_token != null) return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    const name_token = var_decl.ast.mut_token + 1;

    const block = enclosingBlock(builder, decl_node) orelse return;

    // collect all references to the declaration
    var references: std.ArrayList(Ast.TokenIndex) = .empty;
    const decl_end = stmtEndToken(tree, decl_node);
    var t = decl_end + 1;
    while (t < ast.lastToken(tree, block)) : (t += 1) {
        if (tree.tokenTag(t) != .identifier) continue;
        if (tree.tokenTag(t - 1) == .period) continue;
        if (!std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, t), name)) continue;
        const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(t)) orelse continue;
        if (decl.handle != builder.handle or decl.decl != .ast_node or decl.decl.ast_node != decl_node) continue;
        try references.append(builder.arena, t);
    }
    if (references.items.len == 0) return;
    // don't duplicate side effects
    if (references.items.len > 1 and containsCall(tree, init_node)) return;

    const init_text = offsets.nodeToSlice(tree, init_node);
    const needs_result_type = isAnonymousInit(tree, init_node);
    const type_text: ?[]const u8 = if (var_decl.ast.type_node.unwrap()) |type_node| offsets.nodeToSlice(tree, type_node) else null;

    var edits: std.ArrayList(types.TextEdit) = .empty;
    try edits.append(builder.arena, builder.createTextEditLoc(expandToLines(tree.source, stmtLoc(tree, decl_node)), ""));

    for (references.items) |ref| {
        const context = try referenceContext(builder, ref);
        const new_text = if (needs_result_type and type_text != null and !context.has_result_type)
            try builder.arena.print("@as({s}, {s})", .{ type_text.?, init_text })
        else if (!context.allows_any_expression and !isPrimaryExpression(tree, init_node))
            try builder.arena.print("({s})", .{init_text})
        else
            init_text;
        // re-indent multi-line initializers to the indentation of the reference
        const reindented = try reindent(
            builder.arena,
            new_text,
            lineIndent(tree.source, tree.tokenStart(var_decl.firstToken())),
            lineIndent(tree.source, tree.tokenStart(ref)),
            false,
        );
        try edits.append(builder.arena, builder.createTextEditLoc(offsets.tokenToLoc(tree, ref), reindented));
    }

    try builder.actions.append(builder.arena, .{
        .title = try builder.arena.print("inline variable '{s}'", .{offsets.tokenToSlice(tree, name_token)}),
        .kind = .@"refactor.inline",
        .isPreferred = false,
        .edit = try builder.createWorkspaceEdit(edits.items),
    });
}

const ReferenceContext = struct {
    /// The reference is in a location that provides a result type (e.g. function argument, field initializer).
    has_result_type: bool,
    /// The reference can be replaced by any expression without adding parentheses.
    allows_any_expression: bool,
};

fn referenceContext(builder: *Builder, ref: Ast.TokenIndex) error{OutOfMemory}!ReferenceContext {
    const tree = &builder.handle.tree;
    const ancestors = try ast.nodesOverlappingIndex(builder.arena, tree, tree.tokenStart(ref));
    const ident_node = for (ancestors, 0..) |node, i| {
        if (tree.nodeTag(node) == .identifier and tree.nodeMainToken(node) == ref) break i;
    } else return .{ .has_result_type = false, .allows_any_expression = false };
    if (ident_node + 1 >= ancestors.len) return .{ .has_result_type = false, .allows_any_expression = false };
    const node = ancestors[ident_node];
    const parent = ancestors[ident_node + 1];

    var buffer: [2]Ast.Node.Index = undefined;
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, parent)) |call| {
        for (call.ast.params) |param| if (param == node) return .{ .has_result_type = true, .allows_any_expression = true };
        return .{ .has_result_type = false, .allows_any_expression = false };
    }
    if (tree.fullStructInit(&buffer, parent)) |struct_init| {
        for (struct_init.ast.fields) |field| if (field == node) return .{ .has_result_type = true, .allows_any_expression = true };
        return .{ .has_result_type = false, .allows_any_expression = false };
    }
    if (tree.fullArrayInit(&buffer, parent)) |array_init| {
        for (array_init.ast.elements) |elem| if (elem == node) return .{ .has_result_type = true, .allows_any_expression = true };
        return .{ .has_result_type = false, .allows_any_expression = false };
    }
    if (tree.fullVarDecl(parent)) |var_decl| {
        if (var_decl.ast.init_node.unwrap() == node) return .{ .has_result_type = var_decl.ast.type_node != .none, .allows_any_expression = true };
    }
    switch (tree.nodeTag(parent)) {
        .assign => if (tree.nodeData(parent).node_and_node[1] == node) return .{ .has_result_type = true, .allows_any_expression = true },
        .@"return" => return .{ .has_result_type = true, .allows_any_expression = true },
        .grouped_expression => return .{ .has_result_type = false, .allows_any_expression = true },
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => return .{ .has_result_type = false, .allows_any_expression = true },
        .address_of => return .{ .has_result_type = false, .allows_any_expression = false },
        else => {},
    }
    return .{ .has_result_type = false, .allows_any_expression = false };
}

fn isAnonymousInit(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .enum_literal,
        => true,
        else => false,
    };
}

/// Whether the expression binds tighter than any operator, so that it can be placed anywhere without parentheses.
fn isPrimaryExpression(tree: *const Ast, node: Ast.Node.Index) bool {
    var call_buffer: [1]Ast.Node.Index = undefined;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node) != null) return true;
    if (tree.fullStructInit(&buffer, node) != null) return true;
    if (tree.fullArrayInit(&buffer, node) != null) return true;
    return switch (tree.nodeTag(node)) {
        .identifier,
        .number_literal,
        .char_literal,
        .string_literal,
        .multiline_string_literal,
        .enum_literal,
        .error_value,
        .unreachable_literal,
        .field_access,
        .array_access,
        .unwrap_optional,
        .deref,
        .slice,
        .slice_open,
        .slice_sentinel,
        .grouped_expression,
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

fn containsCall(tree: *const Ast, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = ast.lastToken(tree, node);
    var t = first + 1;
    while (t <= last) : (t += 1) {
        if (tree.tokenTag(t) != .l_paren) continue;
        switch (tree.tokenTag(t - 1)) {
            .identifier, .r_paren, .r_bracket => return true,
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// block to expression
// ---------------------------------------------------------------------------

fn blockToExpression(builder: *Builder, ancestors: []const Ast.Node.Index) Error!void {
    const tree = &builder.handle.tree;
    for (ancestors, 0..) |node, i| {
        if (!isBlock(tree, node)) continue;
        if (i + 1 >= ancestors.len) return;
        if (try convertBlockToExpression(builder, node, ancestors[i + 1], ancestors[i + 1 ..])) return;
    }
}

fn convertBlockToExpression(
    builder: *Builder,
    block: Ast.Node.Index,
    parent: Ast.Node.Index,
    outer: []const Ast.Node.Index,
) Error!bool {
    const tree = &builder.handle.tree;

    // statement blocks and function bodies are not expressions
    if (isBlock(tree, parent)) return false;
    switch (tree.nodeTag(parent)) {
        .root, .fn_decl, .test_decl, .@"comptime", .@"nosuspend", .@"suspend" => return false,
        else => {},
    }

    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return false;
    if (statements.len == 0) return false;
    if (statements.len != 1 and ast.blockLabel(tree, block) == null) return false;
    const stmt = statements[statements.len - 1];

    const lbrace = tree.nodeMainToken(block);
    const rbrace = ast.lastToken(tree, block);
    const block_line_indent = lineIndent(tree.source, tree.tokenStart(lbrace));
    const stmt_indent = lineIndent(tree.source, offsets.nodeToLoc(tree, stmt).start);

    if (ast.blockLabel(tree, block)) |label_token| {
        const label = offsets.tokenToSlice(tree, label_token);
        var found_break = false;
        // `if (a) break :blk x; if (b) break :blk y; break :blk z;` -> `if (a) x else if (b) y else z`
        var text: std.ArrayList(u8) = .empty;
        for (statements[0 .. statements.len - 1]) |early| {
            const if_node = ast.fullIf(tree, early) orelse return false;
            if (if_node.ast.else_expr != .none) return false;
            const then_text = try yieldRewrite(builder, if_node.ast.then_expr, .{ .label = label }, &found_break) orelse return false;
            const if_text = try spliceText(builder.arena, tree.source, offsets.nodeToLoc(tree, early), &.{
                .{ .loc = offsets.nodeToLoc(tree, if_node.ast.then_expr), .text = then_text },
            });
            const early_indent = lineIndent(tree.source, offsets.nodeToLoc(tree, early).start);
            try text.appendSlice(builder.arena, try reindent(builder.arena, if_text, early_indent, block_line_indent, false));
            try text.appendSlice(builder.arena, " else ");
        }
        const last_text = try yieldRewrite(builder, stmt, .{ .label = label }, &found_break) orelse return false;
        if (!found_break) return false;
        try text.appendSlice(builder.arena, try reindent(builder.arena, last_text, stmt_indent, block_line_indent, false));
        const new_text = text.items;

        const loc: offsets.Loc = .{ .start = tree.tokenStart(label_token), .end = offsets.tokenToLoc(tree, rbrace).end };
        try builder.actions.append(builder.arena, .{
            .title = "convert labeled block to expression",
            .kind = .@"refactor.rewrite",
            .isPreferred = false,
            .edit = try builder.createWorkspaceEdit(&.{builder.createTextEditLoc(loc, new_text)}),
        });
        return true;
    }

    // unlabeled blocks are only expressions in the body of switch prongs, if, while, for, defer
    const is_branch_body = tree.fullSwitchCase(parent) != null or
        ast.fullIf(tree, parent) != null or
        ast.fullWhile(tree, parent) != null or
        ast.fullFor(tree, parent) != null or
        tree.nodeTag(parent) == .@"defer" or
        tree.nodeTag(parent) == .@"errdefer";
    if (!is_branch_body) return false;

    if (tree.fullVarDecl(stmt) != null) return false;
    switch (tree.nodeTag(stmt)) {
        .@"defer", .@"errdefer", .assign_destructure => return false,
        else => {},
    }

    const next_token = rbrace + 1;
    const followed_by_else = next_token < tree.tokens.len and tree.tokenTag(next_token) == .keyword_else;
    if (followed_by_else) {
        // `if (a) { if (b) x(); } else y();` would change meaning
        if (ast.fullIf(tree, stmt)) |if_node| if (if_node.ast.else_expr == .none) return false;
        if (ast.fullWhile(tree, stmt)) |while_node| if (while_node.ast.else_expr == .none) return false;
        if (ast.fullFor(tree, stmt)) |for_node| if (for_node.ast.else_expr == .none) return false;
    }

    // `if (c) { foo(); }` as a statement needs a semicolon: `if (c) foo();`
    const needs_semicolon = blk: {
        if (tree.fullSwitchCase(parent) != null) break :blk false;
        if (ast.lastToken(tree, parent) != rbrace) break :blk false;
        if (next_token < tree.tokens.len and tree.tokenTag(next_token) == .semicolon) break :blk false;
        if (outer.len < 2) break :blk false;
        break :blk isBlock(tree, outer[1]);
    };

    const stmt_text = offsets.nodeToSlice(tree, stmt);
    const reindented = try reindent(builder.arena, stmt_text, stmt_indent, block_line_indent, false);
    const new_text = if (needs_semicolon) try builder.arena.print("{s};", .{reindented}) else reindented;

    const loc: offsets.Loc = .{ .start = tree.tokenStart(lbrace), .end = offsets.tokenToLoc(tree, rbrace).end };
    try builder.actions.append(builder.arena, .{
        .title = "convert block to expression",
        .kind = .@"refactor.rewrite",
        .isPreferred = false,
        .edit = try builder.createWorkspaceEdit(&.{builder.createTextEditLoc(loc, new_text)}),
    });
    return true;
}

const YieldTarget = union(enum) {
    /// `break :label value`
    label: []const u8,
    /// `name = value`
    assign: []const u8,
};

/// `var x: T = undefined; switch (y) { .a => x = 1, .b => x = 2 }` -> `const x: T = switch (y) { .a => 1, .b => 2 };`
fn assignmentsToExpression(builder: *Builder, ancestors: []const Ast.Node.Index, index: usize) Error!void {
    const tree = &builder.handle.tree;

    const decl_node = for (ancestors) |node| {
        if (tree.fullVarDecl(node) != null) break node;
    } else return;
    const var_decl = tree.fullVarDecl(decl_node).?;
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_var) return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    if (tree.nodeTag(init_node) != .identifier or !std.mem.eql(u8, offsets.nodeToSlice(tree, init_node), "undefined")) return;
    if (index > offsets.nodeToLoc(tree, init_node).end) return;

    const block = enclosingBlock(builder, decl_node) orelse return;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block).?;
    const decl_index = std.mem.findScalar(Ast.Node.Index, statements, decl_node).?;
    if (decl_index + 1 >= statements.len) return;
    const stmt = statements[decl_index + 1];
    if (tree.fullSwitch(stmt) == null and ast.fullIf(tree, stmt) == null) return;

    const name_token = var_decl.ast.mut_token + 1;
    const name = offsets.identifierTokenToNameSlice(tree, name_token);

    var found = false;
    const text = try yieldRewrite(builder, stmt, .{ .assign = name }, &found) orelse return;
    if (!found) return;

    // keep `var` if the variable is modified afterwards
    const is_mutated = blk: {
        var t = stmtEndToken(tree, stmt) + 1;
        while (t < ast.lastToken(tree, block)) : (t += 1) {
            if (tree.tokenTag(t) != .identifier or tree.tokenTag(t - 1) == .period) continue;
            if (!std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, t), name)) continue;
            if (isMutatingUsage(tree, t)) break :blk true;
        }
        break :blk false;
    };

    const type_text = if (var_decl.ast.type_node.unwrap()) |type_node|
        try builder.arena.print(": {s}", .{offsets.nodeToSlice(tree, type_node)})
    else
        "";
    const reindented = try reindent(
        builder.arena,
        text,
        lineIndent(tree.source, offsets.nodeToLoc(tree, stmt).start),
        lineIndent(tree.source, tree.tokenStart(var_decl.firstToken())),
        false,
    );
    const new_text = try builder.arena.print("{s} {s}{s} = {s};", .{
        if (is_mutated) "var" else "const",
        offsets.tokenToSlice(tree, name_token),
        type_text,
        reindented,
    });
    const loc: offsets.Loc = .{ .start = tree.tokenStart(var_decl.firstToken()), .end = stmtLoc(tree, stmt).end };
    try builder.actions.append(builder.arena, .{
        .title = "convert assignments to expression",
        .kind = .@"refactor.rewrite",
        .isPreferred = false,
        .edit = try builder.createWorkspaceEdit(&.{builder.createTextEditLoc(loc, new_text)}),
    });
}

/// Rewrites a statement that yields a value through `break :label value` (or `name = value`) into an expression.
/// Returns `null` if the statement can not be represented as an expression.
fn yieldRewrite(builder: *Builder, node: Ast.Node.Index, target: YieldTarget, found_break: *bool) Error!?[]const u8 {
    const tree = &builder.handle.tree;

    switch (tree.nodeTag(node)) {
        .assign => {
            const name = switch (target) {
                .assign => |name| name,
                .label => return null,
            };
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            if (tree.nodeTag(lhs) != .identifier) return null;
            if (!std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, tree.nodeMainToken(lhs)), name)) return null;
            found_break.* = true;
            return offsets.nodeToSlice(tree, rhs);
        },
        .@"break" => {
            const label_token, const rhs = tree.nodeData(node).opt_token_and_opt_node;
            if (label_token.unwrap()) |lt| {
                if (target == .label and std.mem.eql(u8, offsets.tokenToSlice(tree, lt), target.label)) {
                    found_break.* = true;
                    const value = rhs.unwrap() orelse return "{}";
                    return offsets.nodeToSlice(tree, value);
                }
            }
            return offsets.nodeToSlice(tree, node); // noreturn
        },
        .@"continue", .@"return", .unreachable_literal => return offsets.nodeToSlice(tree, node),
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
            const builtin = offsets.tokenToSlice(tree, tree.nodeMainToken(node));
            for ([_][]const u8{ "@panic", "@compileError", "@trap" }) |noreturn_builtin| {
                if (std.mem.eql(u8, builtin, noreturn_builtin)) return offsets.nodeToSlice(tree, node);
            }
            return null;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            if (ast.blockLabel(tree, node) != null) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            if (statements.len != 1) return null;
            const inner = try yieldRewrite(builder, statements[0], target, found_break) orelse return null;
            return try reindent(
                builder.arena,
                inner,
                lineIndent(tree.source, offsets.nodeToLoc(tree, statements[0]).start),
                lineIndent(tree.source, tree.tokenStart(tree.nodeMainToken(node))),
                false,
            );
        },
        else => {},
    }

    const node_loc = offsets.nodeToLoc(tree, node);
    var splices: std.ArrayList(Splice) = .empty;

    if (tree.fullSwitch(node)) |switch_node| {
        if (switch_node.label_token != null) return null;
        for (switch_node.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node).?;
            const text = try yieldRewrite(builder, case.ast.target_expr, target, found_break) orelse return null;
            try splices.append(builder.arena, .{ .loc = offsets.nodeToLoc(tree, case.ast.target_expr), .text = text });
        }
    } else if (ast.fullIf(tree, node)) |if_node| {
        const else_expr = if_node.ast.else_expr.unwrap() orelse return null;
        for ([_]Ast.Node.Index{ if_node.ast.then_expr, else_expr }) |branch| {
            const text = try yieldRewrite(builder, branch, target, found_break) orelse return null;
            try splices.append(builder.arena, .{ .loc = offsets.nodeToLoc(tree, branch), .text = text });
        }
    } else return null;

    return try spliceText(builder.arena, tree.source, node_loc, splices.items);
}

// ---------------------------------------------------------------------------
// extract function
// ---------------------------------------------------------------------------

const ExtractParam = struct {
    name: []const u8,
    decl_token: Ast.TokenIndex,
    type_text: []const u8,
    is_comptime: bool,
    by_pointer: bool,
    usages: std.ArrayList(Ast.TokenIndex),
};

const ExtractOutput = struct {
    name: []const u8,
    mut: []const u8,
    type_text: []const u8,
    /// `true` if the type was written by the user and should be kept on the call site
    explicit_type: bool,
};

const ExtractMode = union(enum) {
    /// a list of statements inside of a block
    statements,
    /// an unlabeled block statement `{ ... }`
    block_statement: Ast.Node.Index,
    /// a labeled block `blk: { ... break :blk value; }`
    labeled_block: struct { block: Ast.Node.Index, label: []const u8, is_expression: bool, parent: Ast.Node.Index },
};

fn extractFunction(builder: *Builder, selection: offsets.Loc, ancestors: []const Ast.Node.Index) Error!void {
    const tree = &builder.handle.tree;

    var mode: ExtractMode = .statements;
    var statements: []const Ast.Node.Index = &.{};
    // the block that contains `statements`
    var container_block: Ast.Node.Index = .root;

    if (selection.start == selection.end) {
        // the cursor must be on the opening brace or label of a block
        const block = for (ancestors) |node| {
            if (!isBlock(tree, node)) continue;
            const lbrace = tree.nodeMainToken(node);
            const first = if (ast.blockLabel(tree, node)) |label| label else lbrace;
            if (selection.start >= tree.tokenStart(first) and selection.start <= offsets.tokenToLoc(tree, lbrace).end) break node;
        } else return;
        var buffer: [2]Ast.Node.Index = undefined;
        statements = try builder.arena.dupe(Ast.Node.Index, tree.blockStatements(&buffer, block).?);
        if (statements.len == 0) return;
        container_block = block;

        const parent_index = std.mem.findScalar(Ast.Node.Index, ancestors, block).? + 1;
        if (parent_index >= ancestors.len) return;
        const parent = ancestors[parent_index];
        if (ast.blockLabel(tree, block)) |label| {
            mode = .{ .labeled_block = .{ .block = block, .label = offsets.tokenToSlice(tree, label), .is_expression = !isBlock(tree, parent), .parent = parent } };
        } else {
            if (!isBlock(tree, parent)) return; // e.g. a function body
            mode = .{ .block_statement = block };
        }
    } else {
        // find the innermost block whose statements are selected
        for (ancestors) |node| {
            if (!isBlock(tree, node)) continue;
            const block_loc = offsets.nodeToLoc(tree, node);
            if (selection.start <= tree.tokenStart(tree.nodeMainToken(node)) or selection.end > block_loc.end) continue;

            var buffer: [2]Ast.Node.Index = undefined;
            const all_statements = tree.blockStatements(&buffer, node).?;
            var first: ?usize = null;
            var last: usize = 0;
            for (all_statements, 0..) |stmt, i| {
                const stmt_loc = stmtLoc(tree, stmt);
                if (stmt_loc.end > selection.start and stmt_loc.start < selection.end) {
                    if (first == null) first = i;
                    last = i;
                }
            }
            const first_index = first orelse return;
            const first_token_loc = offsets.tokenToLoc(tree, tree.firstToken(all_statements[first_index]));
            const last_token_loc = offsets.tokenToLoc(tree, ast.lastToken(tree, all_statements[last]));
            // the selection must cover the statements from start to end
            if (selection.start > first_token_loc.end or selection.end < last_token_loc.start) return;
            statements = try builder.arena.dupe(Ast.Node.Index, all_statements[first_index .. last + 1]);
            container_block = node;
            break;
        } else return;
    }

    const body_loc: offsets.Loc = .{
        .start = offsets.nodeToLoc(tree, statements[0]).start,
        .end = stmtLoc(tree, statements[statements.len - 1]).end,
    };
    const first_token = tree.firstToken(statements[0]);
    const last_token = stmtEndToken(tree, statements[statements.len - 1]);

    // the function (or test) that contains the selection
    const owner = for (ancestors) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl, .test_decl => break node,
            else => {},
        }
    } else return;
    const owner_loc = offsets.nodeToLoc(tree, owner);

    const label: ?[]const u8 = switch (mode) {
        .labeled_block => |info| info.label,
        else => null,
    };

    // control flow that would escape the new function is not supported
    var has_try = false;
    var labels_in_body: std.ArrayList([]const u8) = .empty;
    {
        var t = first_token;
        while (t <= last_token) : (t += 1) {
            if (tree.tokenTag(t) == .identifier and tree.tokenTag(t + 1) == .colon) switch (tree.tokenTag(t + 2)) {
                .l_brace, .keyword_while, .keyword_for, .keyword_inline, .keyword_switch => try labels_in_body.append(builder.arena, offsets.tokenToSlice(tree, t)),
                else => {},
            };
        }
        t = first_token;
        while (t <= last_token) : (t += 1) {
            switch (tree.tokenTag(t)) {
                .keyword_try => has_try = true,
                .keyword_return => return,
                .keyword_break, .keyword_continue => {
                    if (tree.tokenTag(t + 1) == .colon) {
                        const target = offsets.tokenToSlice(tree, t + 2);
                        if (label != null and std.mem.eql(u8, target, label.?)) continue;
                        for (labels_in_body.items) |l| {
                            if (std.mem.eql(u8, l, target)) break;
                        } else return;
                    } else {
                        const break_ancestors = try ast.nodesOverlappingIndex(builder.arena, tree, tree.tokenStart(t));
                        for (break_ancestors) |node| {
                            if (offsets.nodeToLoc(tree, node).start < body_loc.start) return;
                            if (ast.fullWhile(tree, node) != null or ast.fullFor(tree, node) != null) break;
                        } else return;
                    }
                },
                else => {},
            }
        }
    }

    // collect the variables from the enclosing function that are used inside the selection
    var params: std.ArrayList(ExtractParam) = .empty;
    {
        var t = first_token;
        while (t <= last_token) : (t += 1) {
            if (tree.tokenTag(t) != .identifier) continue;
            switch (tree.tokenTag(t - 1)) {
                .period, .keyword_const, .keyword_var => continue,
                .colon => if (t >= 2 and (tree.tokenTag(t - 2) == .keyword_break or tree.tokenTag(t - 2) == .keyword_continue)) continue,
                else => {},
            }
            if (tree.tokenTag(t + 1) == .colon) switch (tree.tokenTag(t + 2)) {
                .l_brace, .keyword_while, .keyword_for, .keyword_inline, .keyword_switch => continue,
                else => {},
            };

            const name = offsets.identifierTokenToNameSlice(tree, t);
            const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(t)) orelse continue;
            if (decl.handle != builder.handle) continue;
            if (decl.decl == .label) continue;
            const decl_token = decl.nameToken();
            const decl_index = tree.tokenStart(decl_token);
            if (decl_index >= body_loc.start and decl_index < body_loc.end) continue; // declared inside of the selection
            if (decl_index < owner_loc.start or decl_index >= owner_loc.end) continue; // container level declaration

            const param = for (params.items) |*param| {
                if (param.decl_token == decl_token) break param;
            } else blk: {
                const type_text, const is_comptime = try declTypeText(builder, decl) orelse .{ "anytype", false };
                try params.append(builder.arena, .{
                    .name = offsets.tokenToSlice(tree, decl_token),
                    .decl_token = decl_token,
                    .type_text = type_text,
                    .is_comptime = is_comptime,
                    .by_pointer = false,
                    .usages = .empty,
                });
                break :blk &params.items[params.items.len - 1];
            };
            try param.usages.append(builder.arena, t);

            if (!param.by_pointer and decl.decl == .ast_node and !param.is_comptime) {
                if (tree.fullVarDecl(decl.decl.ast_node)) |var_decl| {
                    if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_var and isMutatingUsage(tree, t)) {
                        param.by_pointer = true;
                    }
                }
            }
        }
    }

    // declarations inside of the selection that are used after it
    var outputs: std.ArrayList(ExtractOutput) = .empty;
    if (mode == .statements) {
        for (statements) |stmt| {
            const var_decl = tree.fullVarDecl(stmt) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            const name = offsets.identifierTokenToNameSlice(tree, name_token);
            var t = last_token + 1;
            const used_after = while (t < ast.lastToken(tree, container_block)) : (t += 1) {
                if (tree.tokenTag(t) != .identifier or tree.tokenTag(t - 1) == .period) continue;
                if (!std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, t), name)) continue;
                const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(t)) orelse continue;
                if (decl.decl == .ast_node and decl.decl.ast_node == stmt) break true;
            } else false;
            if (!used_after) continue;

            const decl: Analyser.DeclWithHandle = .{ .decl = .{ .ast_node = stmt }, .handle = builder.handle };
            const type_text, const is_comptime = try declTypeText(builder, decl) orelse return;
            if (is_comptime) return;
            try outputs.append(builder.arena, .{
                .name = offsets.tokenToSlice(tree, name_token),
                .mut = offsets.tokenToSlice(tree, var_decl.ast.mut_token),
                .type_text = type_text,
                .explicit_type = var_decl.ast.type_node != .none,
            });
        }
        // destructuring declarations that escape the selection are not supported
        for (statements) |stmt| {
            if (tree.nodeTag(stmt) != .assign_destructure) continue;
            const stmt_loc = stmtLoc(tree, stmt);
            _ = stmt_loc;
            var t = last_token + 1;
            while (t < ast.lastToken(tree, container_block)) : (t += 1) {
                if (tree.tokenTag(t) != .identifier or tree.tokenTag(t - 1) == .period) continue;
                const name = offsets.identifierTokenToNameSlice(tree, t);
                const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(t)) orelse continue;
                if (decl.decl == .assign_destructure and decl.decl.assign_destructure.node == stmt) return;
            }
        }
    }

    const return_type_base: []const u8 = switch (mode) {
        .statements => switch (outputs.items.len) {
            0 => "void",
            1 => outputs.items[0].type_text,
            else => blk: {
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(builder.arena, "struct { ");
                for (outputs.items, 0..) |output, i| {
                    if (i != 0) try text.appendSlice(builder.arena, ", ");
                    try text.appendSlice(builder.arena, output.type_text);
                }
                try text.appendSlice(builder.arena, " }");
                break :blk text.items;
            },
        },
        .block_statement => "void",
        .labeled_block => |info| blk: {
            if (!info.is_expression) break :blk "void";
            if (try declaredResultType(builder, info.parent, info.block)) |text| break :blk text;
            const ty = try builder.analyser.resolveTypeOfNode(.of(info.block, builder.handle)) orelse return;
            const text = try ty.stringifyTypeOf(builder.analyser, .{ .truncate_container_decls = true });
            if (!isUsableTypeText(text)) return;
            break :blk text;
        },
    };
    const return_type = if (has_try) try builder.arena.print("!{s}", .{return_type_base}) else return_type_base;

    // choose a name that is not used in this file
    const fn_name = blk: {
        var i: usize = 1;
        while (true) : (i += 1) {
            const candidate = if (i == 1) "extracted" else try builder.arena.print("extracted{d}", .{i});
            if (!identifierExists(tree, candidate)) break :blk candidate;
        }
    };

    // build the body of the new function
    var splices: std.ArrayList(Splice) = .empty;
    for (params.items) |param| {
        if (!param.by_pointer) continue;
        for (param.usages.items) |usage| {
            if (tree.tokenTag(usage - 1) == .ampersand) {
                try splices.append(builder.arena, .{ .loc = .{ .start = tree.tokenStart(usage - 1), .end = offsets.tokenToLoc(tree, usage).end }, .text = param.name });
            } else if (tree.tokenTag(usage + 1) == .period and tree.tokenTag(usage + 2) == .identifier) {
                // field access and method calls automatically dereference single item pointers
            } else {
                try splices.append(builder.arena, .{ .loc = offsets.tokenToLoc(tree, usage), .text = try builder.arena.print("{s}.*", .{param.name}) });
            }
        }
    }
    if (label) |l| {
        // `break :label value` -> `return value`
        var t = first_token;
        while (t <= last_token) : (t += 1) {
            if (tree.tokenTag(t) != .keyword_break or tree.tokenTag(t + 1) != .colon) continue;
            if (!std.mem.eql(u8, offsets.tokenToSlice(tree, t + 2), l)) continue;
            try splices.append(builder.arena, .{ .loc = .{ .start = tree.tokenStart(t), .end = offsets.tokenToLoc(tree, t + 2).end }, .text = "return" });
        }
    }
    std.mem.sort(Splice, splices.items, {}, Splice.lessThan);
    const raw_body = try spliceText(builder.arena, tree.source, body_loc, splices.items);

    const fn_indent = lineIndent(tree.source, owner_loc.start);
    const indent_unit = detectIndentUnit(tree.source);
    const body_indent = try builder.arena.print("{s}{s}", .{ fn_indent, indent_unit });
    const body = try reindent(builder.arena, raw_body, lineIndent(tree.source, body_loc.start), body_indent, true);

    var fn_text: std.ArrayList(u8) = .empty;
    try fn_text.print(builder.arena, "\n\n{s}fn {s}(", .{ fn_indent, fn_name });
    for (params.items, 0..) |param, i| {
        if (i != 0) try fn_text.appendSlice(builder.arena, ", ");
        if (param.is_comptime) try fn_text.appendSlice(builder.arena, "comptime ");
        try fn_text.print(builder.arena, "{s}: {s}{s}", .{ param.name, if (param.by_pointer) "*" else "", param.type_text });
    }
    try fn_text.print(builder.arena, ") {s} {{\n{s}\n", .{ return_type, body });
    switch (outputs.items.len) {
        0 => {},
        1 => try fn_text.print(builder.arena, "{s}return {s};\n", .{ body_indent, outputs.items[0].name }),
        else => {
            try fn_text.print(builder.arena, "{s}return .{{ ", .{body_indent});
            for (outputs.items, 0..) |output, i| {
                if (i != 0) try fn_text.appendSlice(builder.arena, ", ");
                try fn_text.appendSlice(builder.arena, output.name);
            }
            try fn_text.appendSlice(builder.arena, " };\n");
        },
    }
    try fn_text.print(builder.arena, "{s}}}", .{fn_indent});

    // build the call site
    var call: std.ArrayList(u8) = .empty;
    if (has_try) try call.appendSlice(builder.arena, "try ");
    try call.print(builder.arena, "{s}(", .{fn_name});
    for (params.items, 0..) |param, i| {
        if (i != 0) try call.appendSlice(builder.arena, ", ");
        if (param.by_pointer) try call.append(builder.arena, '&');
        try call.appendSlice(builder.arena, param.name);
    }
    try call.append(builder.arena, ')');

    const replace_loc: offsets.Loc, const call_text: []const u8 = switch (mode) {
        .statements => .{ body_loc, switch (outputs.items.len) {
            0 => try builder.arena.print("{s};", .{call.items}),
            1 => blk: {
                const output = outputs.items[0];
                if (output.explicit_type) break :blk try builder.arena.print("{s} {s}: {s} = {s};", .{ output.mut, output.name, output.type_text, call.items });
                break :blk try builder.arena.print("{s} {s} = {s};", .{ output.mut, output.name, call.items });
            },
            else => blk: {
                var text: std.ArrayList(u8) = .empty;
                for (outputs.items, 0..) |output, i| {
                    if (i != 0) try text.appendSlice(builder.arena, ", ");
                    try text.print(builder.arena, "{s} {s}", .{ output.mut, output.name });
                }
                try text.print(builder.arena, " = {s};", .{call.items});
                break :blk text.items;
            },
        } },
        .block_statement => |block| .{ blockLoc(tree, block), try builder.arena.print("{s};", .{call.items}) },
        .labeled_block => |info| .{
            blockLoc(tree, info.block),
            if (info.is_expression) call.items else try builder.arena.print("{s};", .{call.items}),
        },
    };

    const insert_index = offsets.nodeToLoc(tree, owner).end;
    try builder.actions.append(builder.arena, .{
        .title = "extract into function",
        .kind = .@"refactor.extract",
        .isPreferred = false,
        .edit = try builder.createWorkspaceEdit(&.{
            builder.createTextEditLoc(replace_loc, call_text),
            builder.createTextEditPos(insert_index, fn_text.items),
        }),
    });
}

/// If `expr` initializes a declaration with an explicit type, returns that type as source text.
/// `const a: A, const b: B = expr;` returns `struct { A, B }`.
fn declaredResultType(builder: *Builder, parent: Ast.Node.Index, expr: Ast.Node.Index) error{OutOfMemory}!?[]const u8 {
    const tree = &builder.handle.tree;
    if (tree.fullVarDecl(parent)) |var_decl| {
        if (var_decl.ast.init_node.unwrap() != expr) return null;
        const type_node = var_decl.ast.type_node.unwrap() orelse return null;
        return offsets.nodeToSlice(tree, type_node);
    }
    if (tree.nodeTag(parent) != .assign_destructure) return null;
    const destructure = tree.assignDestructure(parent);
    if (destructure.ast.value_expr != expr) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(builder.arena, "struct { ");
    for (destructure.ast.variables, 0..) |variable, i| {
        const var_decl = tree.fullVarDecl(variable) orelse return null;
        const type_node = var_decl.ast.type_node.unwrap() orelse return null;
        if (i != 0) try text.appendSlice(builder.arena, ", ");
        try text.appendSlice(builder.arena, offsets.nodeToSlice(tree, type_node));
    }
    try text.appendSlice(builder.arena, " }");
    return text.items;
}

/// Returns the type of the declaration as source text and whether it has to be a comptime parameter.
fn declTypeText(builder: *Builder, decl: Analyser.DeclWithHandle) Error!?struct { []const u8, bool } {
    const tree = &decl.handle.tree;
    switch (decl.decl) {
        .function_parameter => |payload| blk: {
            const param = payload.get(tree) orelse break :blk;
            const is_comptime = if (param.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false;
            if (param.anytype_ellipsis3 != null) return .{ "anytype", is_comptime };
            const type_expr = param.type_expr orelse break :blk;
            const text = offsets.nodeToSlice(tree, type_expr);
            return .{ text, is_comptime or std.mem.eql(u8, text, "type") };
        },
        .ast_node => |node| if (tree.fullVarDecl(node)) |var_decl| {
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                const text = offsets.nodeToSlice(tree, type_node);
                return .{ text, isComptimeOnlyType(text) };
            }
        },
        else => {},
    }

    const ty = try decl.resolveType(builder.analyser) orelse return null;
    if (ty.is_type_val) return .{ "type", true };
    const text = try ty.stringifyTypeOf(builder.analyser, .{ .truncate_container_decls = true });
    if (!isUsableTypeText(text)) return null;
    return .{ text, isComptimeOnlyType(text) };
}

fn isComptimeOnlyType(text: []const u8) bool {
    for ([_][]const u8{ "type", "comptime_int", "comptime_float", "@EnumLiteral()", "@TypeOf(.enum_literal)" }) |t| {
        if (std.mem.eql(u8, text, t)) return true;
    }
    return false;
}

/// Whether a stringified type can be written in source code.
fn isUsableTypeText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.findScalar(u8, text, '{') != null) return false; // anonymous containers
    if (std.mem.find(u8, text, "unknown") != null) return false;
    if (std.mem.eql(u8, text, "@TypeOf(undefined)")) return false;
    return true;
}

/// Whether the variable at `token` may be modified by the expression it is in.
fn isMutatingUsage(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (tree.tokenTag(token - 1) == .ampersand) return true;
    var t = token + 1;
    while (t < tree.tokens.len) {
        switch (tree.tokenTag(t)) {
            .period => {
                if (tree.tokenTag(t + 1) != .identifier) break;
                if (tree.tokenTag(t + 2) == .l_paren) return true; // method call may take a mutable pointer
                t += 2;
            },
            .period_asterisk => t += 1,
            .l_bracket => {
                var depth: usize = 0;
                while (t < tree.tokens.len) : (t += 1) {
                    switch (tree.tokenTag(t)) {
                        .l_bracket => depth += 1,
                        .r_bracket => {
                            depth -= 1;
                            if (depth == 0) break;
                        },
                        else => {},
                    }
                }
                t += 1;
            },
            else => break,
        }
    }
    if (t >= tree.tokens.len) return false;
    return switch (tree.tokenTag(t)) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .ampersand_equal,
        .pipe_equal,
        .caret_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_right_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .plus_percent_equal,
        .minus_percent_equal,
        .asterisk_percent_equal,
        .plus_pipe_equal,
        .minus_pipe_equal,
        .asterisk_pipe_equal,
        => true,
        else => false,
    };
}

fn identifierExists(tree: *const Ast, name: []const u8) bool {
    for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        if (std.mem.eql(u8, offsets.tokenToSlice(tree, @intCast(i)), name)) return true;
    }
    return false;
}

fn detectIndentUnit(source: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '\t') return "\t";
        const spaces = std.mem.findNone(u8, line, " ") orelse continue;
        if (spaces == 0) continue;
        if (line[spaces] == '/' or line[spaces] == '\\') continue;
        return line[0..spaces];
    }
    return "    ";
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const Splice = struct {
    loc: offsets.Loc,
    text: []const u8,

    fn lessThan(_: void, a: Splice, b: Splice) bool {
        return a.loc.start < b.loc.start;
    }
};

/// Returns `source[base.start..base.end]` with the given (sorted, non-overlapping) ranges replaced.
fn spliceText(arena: std.mem.Allocator, source: []const u8, base: offsets.Loc, splices: []const Splice) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos = base.start;
    for (splices) |splice| {
        std.debug.assert(splice.loc.start >= pos and splice.loc.end <= base.end);
        try out.appendSlice(arena, source[pos..splice.loc.start]);
        try out.appendSlice(arena, splice.text);
        pos = splice.loc.end;
    }
    try out.appendSlice(arena, source[pos..base.end]);
    return out.items;
}

fn isBlock(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// The location of a block including its label.
fn blockLoc(tree: *const Ast, block: Ast.Node.Index) offsets.Loc {
    const first = ast.blockLabel(tree, block) orelse tree.nodeMainToken(block);
    return .{ .start = tree.tokenStart(first), .end = offsets.nodeToLoc(tree, block).end };
}

/// Returns the block of which `node` is a direct statement.
fn enclosingBlock(builder: *Builder, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &builder.handle.tree;
    const ancestors = ast.nodesOverlappingIndex(builder.arena, tree, offsets.nodeToLoc(tree, node).start) catch return null;
    for (ancestors) |ancestor| {
        if (!isBlock(tree, ancestor)) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, ancestor).?;
        if (std.mem.findScalar(Ast.Node.Index, statements, node) != null) return ancestor;
        return null;
    }
    return null;
}

/// The last token of a statement including the trailing semicolon.
fn stmtEndToken(tree: *const Ast, node: Ast.Node.Index) Ast.TokenIndex {
    const last = ast.lastToken(tree, node);
    if (last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .semicolon) return last + 1;
    return last;
}

/// The location of a statement including the trailing semicolon.
fn stmtLoc(tree: *const Ast, node: Ast.Node.Index) offsets.Loc {
    return .{
        .start = offsets.nodeToLoc(tree, node).start,
        .end = offsets.tokenToLoc(tree, stmtEndToken(tree, node)).end,
    };
}

/// Extends the location to cover entire lines if there is only whitespace before and after it.
fn expandToLines(source: []const u8, loc: offsets.Loc) offsets.Loc {
    const line_start = lineStart(source, loc.start);
    if (std.mem.trim(u8, source[line_start..loc.start], " \t").len != 0) return loc;
    var end = loc.end;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t' or source[end] == '\r')) end += 1;
    if (end < source.len and source[end] != '\n') return loc;
    return .{ .start = line_start, .end = @min(end + 1, source.len) };
}

fn lineStart(source: []const u8, index: usize) usize {
    return if (std.mem.findScalarLast(u8, source[0..index], '\n')) |i| i + 1 else 0;
}

/// Returns the leading whitespace of the line that contains `index`.
fn lineIndent(source: []const u8, index: usize) []const u8 {
    const start = lineStart(source, index);
    const end = std.mem.findNonePos(u8, source, start, " \t") orelse source.len;
    return source[start..@min(end, index)];
}

/// Replaces the `old` indentation prefix of every line with `new`.
/// The first line is only indented if `indent_first` is set.
fn reindent(arena: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8, indent_first: bool) error{OutOfMemory}![]const u8 {
    if (std.mem.findScalar(u8, text, '\n') == null and !indent_first) return text;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| : (first = false) {
        if (!first) try out.append(arena, '\n');
        if (first and !indent_first) {
            try out.appendSlice(arena, line);
            continue;
        }
        const stripped = if (std.mem.startsWith(u8, line, old)) line[old.len..] else std.mem.trimStart(u8, line, " \t");
        if (stripped.len != 0) try out.appendSlice(arena, new);
        try out.appendSlice(arena, stripped);
    }
    return out.items;
}
