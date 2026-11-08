const std = @import("std");
const zls = @import("zls");

const Context = @import("../context.zig").Context;
const helper = @import("../helper.zig");

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "discard value" {
    try testAutofix(
        \\test {
        \\    var foo = {};
        \\    const bar, var baz = .{ 1, 2 };
        \\}
        \\
    ,
        \\test {
        \\    var foo = {};
        \\    _ = foo; // autofix
        \\    const bar, var baz = .{ 1, 2 };
        \\    _ = baz; // autofix
        \\    _ = bar; // autofix
        \\}
        \\
    );
}

test "discard value with comments" {
    try testAutofix(
        \\test {
        \\    const a = {}; // a comment
        \\    const b = {} // a comment
        \\    ;
        \\    const c = // a comment
        \\    {};
        \\    const d // a comment
        \\    = {};
        \\}
        \\
    ,
        \\test {
        \\    const a = {}; // a comment
        \\    _ = a; // autofix
        \\    const b = {} // a comment
        \\    ;
        \\    _ = b; // autofix
        \\    const c = // a comment
        \\    {};
        \\    _ = c; // autofix
        \\    const d // a comment
        \\    = {};
        \\    _ = d; // autofix
        \\}
        \\
    );
}

test "discard value with escaped identifier" {
    try testAutofix(
        \\test {
        \\    var @"struct" = {};
        \\    const bar, var @"union" = .{ 1, 2 };
        \\}
        \\
    ,
        \\test {
        \\    var @"struct" = {};
        \\    _ = @"struct"; // autofix
        \\    const bar, var @"union" = .{ 1, 2 };
        \\    _ = @"union"; // autofix
        \\    _ = bar; // autofix
        \\}
        \\
    );
}

test "discard function parameter" {
    try testAutofix(
        \\fn foo(a: void, b: void, c: void) void {}
        \\
    ,
        \\fn foo(a: void, b: void, c: void) void {
        \\    _ = a; // autofix
        \\    _ = b; // autofix
        \\    _ = c; // autofix
        \\}
        \\
    );
    try testAutofix(
        \\fn foo(a: void, b: void, c: void,) void {}
        \\
    ,
        \\fn foo(a: void, b: void, c: void,) void {
        \\    _ = a; // autofix
        \\    _ = b; // autofix
        \\    _ = c; // autofix
        \\}
        \\
    );
}

test "discard function parameter with comments" {
    try testAutofix(
        \\fn foo(a: void) void { // a comment
        \\}
        \\
    ,
        \\fn foo(a: void) void { // a comment
        \\    _ = a; // autofix
        \\}
        \\
    );
    try testAutofix(
        \\fn foo(a: void) void {
        \\    // a comment
        \\}
        \\
    ,
        \\fn foo(a: void) void {
        \\    _ = a; // autofix
        \\    // a comment
        \\}
        \\
    );
}

test "discard captures" {
    try testAutofix(
        \\test {
        \\    for (0..10, 0..10, 0..10) |i, @"test", k| {}
        \\    switch (union(enum) {}{}) {
        \\        inline .a => |cap, tag| {},
        \\    }
        \\    if (null) |x| {}
        \\    if (null) |v| {} else |e| {}
        \\    _ = null catch |e| {};
        \\    _ = null catch |_| {};
        \\}
        \\
    ,
        \\test {
        \\    for (0..10, 0..10, 0..10) |i, @"test", k| {
        \\        _ = i; // autofix
        \\        _ = @"test"; // autofix
        \\        _ = k; // autofix
        \\    }
        \\    switch (union(enum) {}{}) {
        \\        inline .a => |cap, tag| {
        \\            _ = cap; // autofix
        \\            _ = tag; // autofix
        \\        },
        \\    }
        \\    if (null) |x| {
        \\        _ = x; // autofix
        \\    }
        \\    if (null) |v| {
        \\        _ = v; // autofix
        \\    } else |e| {
        \\        _ = e; // autofix
        \\    }
        \\    _ = null catch |e| {
        \\        _ = e; // autofix
        \\    };
        \\    _ = null catch |_| {};
        \\}
        \\
    );
}

test "discard capture with comment" {
    try testAutofix(
        \\test {
        \\    if (1 == 1) |a| // a comment
        \\    {}
        \\    for (0..10, 0..10, 0..10) |i, j, k| // a comment
        \\    {}
        \\}
        \\
    ,
        \\test {
        \\    if (1 == 1) |a| // a comment
        \\    {
        \\        _ = a; // autofix
        \\    }
        \\    for (0..10, 0..10, 0..10) |i, j, k| // a comment
        \\    {
        \\        _ = i; // autofix
        \\        _ = j; // autofix
        \\        _ = k; // autofix
        \\    }
        \\}
        \\
    );
    try testAutofix(
        \\test {
        \\    if (1 == 1) |a|
        \\    // a comment
        \\    {}
        \\    for (0..10, 0..10, 0..10) |i, j, k|
        \\    // a comment
        \\    {}
        \\}
        \\
    ,
        \\test {
        \\    if (1 == 1) |a|
        \\    // a comment
        \\    {
        \\        _ = a; // autofix
        \\    }
        \\    for (0..10, 0..10, 0..10) |i, j, k|
        \\    // a comment
        \\    {
        \\        _ = i; // autofix
        \\        _ = j; // autofix
        \\        _ = k; // autofix
        \\    }
        \\}
        \\
    );
    try testAutofix(
        \\test {
        \\    if (1 == 1) |a| { // a comment
        \\    }
        \\    for (0..10, 0..10, 0..10) |i, j, k| { // a comment
        \\    }
        \\}
        \\
    ,
        \\test {
        \\    if (1 == 1) |a| { // a comment
        \\        _ = a; // autofix
        \\    }
        \\    for (0..10, 0..10, 0..10) |i, j, k| { // a comment
        \\        _ = i; // autofix
        \\        _ = j; // autofix
        \\        _ = k; // autofix
        \\    }
        \\}
        \\
    );
}

test "discard capture - while loop with continue" {
    try testAutofix(
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += 1) {}
        \\}
        \\
    ,
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += 1) {
        \\        _ = line; // autofix
        \\    }
        \\}
        \\
    );

    try testAutofix(
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += (1 * (2 + 1))) {}
        \\}
        \\
    ,
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += (1 * (2 + 1))) {
        \\        _ = line; // autofix
        \\    }
        \\}
        \\
    );
    try testAutofix(
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += ")))".len) {}
        \\}
        \\
    ,
        \\test {
        \\    var lines: ?[]const u8 = "";
        \\    var linei: usize = 0;
        \\    while (lines.next()) |line| : (linei += ")))".len) {
        \\        _ = line; // autofix
        \\    }
        \\}
        \\
    );
}

test "remove pointless discard" {
    try testAutofix(
        \\fn foo(a: u32) u32 {
        \\    _ = a; // autofix
        \\    const @"struct": ?u32 = a;
        \\    _ = @"struct"; // autofix
        \\    const c = @"struct";
        \\    _ = c; // autofix
        \\    if (c) |d| {
        \\        _ = d; // autofix
        \\        return d;
        \\    }
        \\    return 0;
        \\}
        \\
    ,
        \\fn foo(a: u32) u32 {
        \\    const @"struct": ?u32 = a;
        \\    const c = @"struct";
        \\    if (c) |d| {
        \\        return d;
        \\    }
        \\    return 0;
        \\}
        \\
    );
}

test "remove discard of unknown identifier" {
    try testAutofix(
        \\fn foo() void {
        \\    _ = a; // autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
    try testAutofix(
        \\fn foo() void {
        \\    _ = @"struct"; // autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
}

test "ignore autofix comment whitespace" {
    try testAutofix(
        \\fn foo() void {
        \\    _ = a; // autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
    try testAutofix(
        \\fn foo() void {
        \\    _ = a;// autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
    try testAutofix(
        \\fn foo() void {
        \\    _ = a;//autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
    try testAutofix(
        \\fn foo() void {
        \\    _ = @"struct";   //   autofix
        \\}
        \\
    ,
        \\fn foo() void {
        \\}
        \\
    );
}

test "remove function parameter" {
    try testDiagnostic(
        \\fn foo(alpha: u32) void {}
    ,
        \\fn foo() void {}
    , .{ .filter_title = "remove function parameter" });
    try testDiagnostic(
        \\fn foo(
        \\    @"struct": u32,
        \\) void {}
    ,
        \\fn foo() void {}
    , .{ .filter_title = "remove function parameter" });
}

test "variable never mutated" {
    try testDiagnostic(
        \\test {
        \\    var foo = 5;
        \\    _ = foo;
        \\}
    ,
        \\test {
        \\    const foo = 5;
        \\    _ = foo;
        \\}
    , .{ .filter_title = "use 'const'" });
    try testDiagnostic(
        \\test {
        \\    var @"struct" = 5;
        \\    _ = @"struct";
        \\}
    ,
        \\test {
        \\    const @"struct" = 5;
        \\    _ = @"struct";
        \\}
    , .{ .filter_title = "use 'const'" });
}

test "discard capture name" {
    try testDiagnostic(
        \\test {
        \\    const maybe: ?u32 = 5;
        \\    if (maybe) |value| {}
        \\}
    ,
        \\test {
        \\    const maybe: ?u32 = 5;
        \\    if (maybe) |_| {}
        \\}
    , .{ .filter_title = "discard capture name" });
}

test "remove capture" {
    // TODO fix whitespace
    try testDiagnostic(
        \\test {
        \\    const maybe: ?u32 = 5;
        \\    if (maybe) |value| {}
        \\}
    ,
        \\test {
        \\    const maybe: ?u32 = 5;
        \\    if (maybe)  {}
        \\}
    , .{ .filter_title = "remove capture" });
}

test "organize imports" {
    try testOrganizeImports(
        \\const xyz = @import("xyz.zig");
        \\const abc = @import("abc.zig");
    ,
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig");
        \\
        \\
    );
    // Three different import groups: std, build_options and builtin, but these groups do not have separator
    // Builtin comes before build_options despite alphabetical order (they are different import kinds)
    // Case insensitive, pub is preserved
    try testOrganizeImports(
        \\const std = @import("std");
        \\const abc = @import("abc.zig");
        \\const build_options = @import("build_options");
        \\const builtin = @import("builtin");
        \\const tres = @import("tres");
        \\
        \\pub const offsets = @import("offsets.zig");
        \\const Config = @import("Config.zig");
        \\const debug = @import("debug.zig");
        \\const Server = @import("Server.zig");
        \\const root = @import("root");
    ,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const root = @import("root");
        \\const build_options = @import("build_options");
        \\
        \\const tres = @import("tres");
        \\
        \\const abc = @import("abc.zig");
        \\const Config = @import("Config.zig");
        \\const debug = @import("debug.zig");
        \\pub const offsets = @import("offsets.zig");
        \\const Server = @import("Server.zig");
        \\
        \\
    );
    // Relative paths are sorted by import path
    try testOrganizeImports(
        \\const y = @import("a/file2.zig");
        \\const x = @import("a/file3.zig");
        \\const z = @import("a/file1.zig");
    ,
        \\const z = @import("a/file1.zig");
        \\const y = @import("a/file2.zig");
        \\const x = @import("a/file3.zig");
        \\
        \\
    );
}

test "organize imports - bubbles up" {
    try testOrganizeImports(
        \\const std = @import("std");
        \\fn main() void {}
        \\const abc = @import("abc.zig");
        \\fn foo() void {}
    ,
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\
        \\fn main() void {}
        \\fn foo() void {}
    );
}

test "organize imports - bottom placement" {
    // When imports are at the bottom, they should stay at the bottom
    try testOrganizeImports(
        \\fn main() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
        \\
        \\const xyz = @import("xyz.zig");
        \\const abc = @import("abc.zig");
        \\const std = @import("std");
    ,
        \\fn main() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
        \\
        \\
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig");
        \\
        \\
    );
}

test "organize imports - bottom placement with multiple functions" {
    // Bottom imports with multiple declarations
    try testOrganizeImports(
        \\fn foo() void {}
        \\
        \\fn bar() void {}
        \\
        \\const test_input = "test";
        \\
        \\const xyz = @import("xyz.zig");
        \\const abc = @import("abc.zig");
        \\const std = @import("std");
    ,
        \\fn foo() void {}
        \\
        \\fn bar() void {}
        \\
        \\const test_input = "test";
        \\
        \\
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig");
        \\
        \\
    );
}

test "organize imports - mixed placement defaults to bottom" {
    // When imports are mixed (both top and bottom), consolidate at bottom
    try testOrganizeImports(
        \\const std = @import("std");
        \\
        \\fn main() void {}
        \\
        \\const xyz = @import("xyz.zig");
        \\const abc = @import("abc.zig");
    ,
        \\fn main() void {}
        \\
        \\
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig");
        \\
        \\
    );
}

test "organize imports - scope" {
    // Ignore imports not in root scope
    try testOrganizeImports(
        \\const b = @import("a.zig");
        \\const a = @import("b.zig");
        \\fn main() void {
        \\  const y = @import("y");
        \\  const x = @import("x");
        \\  _ = y; // autofix
        \\  _ = x; // autofix
        \\}
    ,
        \\const a = @import("b.zig");
        \\const b = @import("a.zig");
        \\
        \\fn main() void {
        \\  const y = @import("y");
        \\  const x = @import("x");
        \\  _ = y; // autofix
        \\  _ = x; // autofix
        \\}
    );
}

test "organize imports - comments" {
    // Doc comments are preserved
    try testOrganizeImports(
        \\const xyz = @import("xyz.zig");
        \\/// Do not look inside
        \\const abc = @import("abc.zig");
    ,
        \\/// Do not look inside
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig");
        \\
        \\
    );
    // Respects top-level doc-comment
    try testOrganizeImports(
        \\//! A module doc
        \\//! Another line
        \\
        \\const abc = @import("abc.zig");
        \\const std = @import("std");
    ,
        \\//! A module doc
        \\//! Another line
        \\
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\
        \\
    );
}

test "organize imports - field access" {
    // field access on import
    try testOrganizeImports(
        \\const xyz = @import("xyz.zig").a.long.chain;
        \\const abc = @import("abc.zig");
    ,
        \\const abc = @import("abc.zig");
        \\const xyz = @import("xyz.zig").a.long.chain;
        \\
        \\
    );
    // declarations without @import move under the parent import
    try testOrganizeImports(
        \\const xyz = @import("xyz.zig").a.long.chain;
        \\const abc = @import("abc.zig");
        \\const abc_related = abc.related;
    ,
        \\const abc = @import("abc.zig");
        \\const abc_related = abc.related;
        \\const xyz = @import("xyz.zig").a.long.chain;
        \\
        \\
    );
    try testOrganizeImports(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\const mem = std.mem;
    ,
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const builtin = @import("builtin");
        \\
        \\
    );
    // Inverse chain of parents
    try testOrganizeImports(
        \\const abc = @import("abc.zig");
        \\const isLower = ascii.isLower;
        \\const ascii = std.ascii;
        \\const std = @import("std");
    ,
        \\const std = @import("std");
        \\const ascii = std.ascii;
        \\const isLower = ascii.isLower;
        \\
        \\const abc = @import("abc.zig");
        \\
        \\
    );
    // Parent chains are not mixed
    try testOrganizeImports(
        \\const xyz = @import("xyz.zig");
        \\const abc = @import("abc.zig");
        \\const xyz_related = xyz.related;
        \\/// comment
        \\const abc_related = abc.related;
    ,
        \\const abc = @import("abc.zig");
        \\/// comment
        \\const abc_related = abc.related;
        \\const xyz = @import("xyz.zig");
        \\const xyz_related = xyz.related;
        \\
        \\
    );
}

test "organize imports - @embedFile" {
    try testOrganizeImports(
        \\const foo = @embedFile("foo.zig");
        \\const abc = @import("abc.zig");
        \\const bar = @embedFile("bar.zig");
    ,
        \\const abc = @import("abc.zig");
        \\
        \\const foo = @embedFile("foo.zig");
        \\const bar = @embedFile("bar.zig");
    );
}

test "organize imports - edge cases" {
    // Withstands non-standard behavior
    try testOrganizeImports(
        \\const std = @import("std");
        \\const abc = @import("abc.zig");
        \\const std = @import("std");
    ,
        \\const std = @import("std");
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\
        \\
    );
}

test "organize imports - no action when already organized" {
    // Single import plus the trailing blank line that organize would normalize to.
    // https://github.com/zigtools/zls/issues/2523
    try testOrganizeImportsNoAction(
        \\const a = @import("a");
        \\
        \\
    );
    // Sorted imports from different kinds with the expected group separator and trailing blank line.
    try testOrganizeImportsNoAction(
        \\const std = @import("std");
        \\
        \\const abc = @import("abc.zig");
        \\
        \\
    );
    // Imports already sorted, separated from following decls by the expected blank line.
    try testOrganizeImportsNoAction(
        \\const std = @import("std");
        \\
        \\fn main() void {}
        \\
    );
}

test "convert multiline string literal" {
    try testConvertString(
        \\const foo = \\Hell<cursor>o
        \\            \\World
        \\;
    ,
        \\const foo = "Hello\nWorld";
    );
    // Empty
    try testConvertString(
        \\const foo = \\<cursor>
        \\;
    ,
        \\const foo = "";
    );
    // Multi-byte characters
    try testConvertString(
        \\const foo = \\He😂ll<cursor>o
        \\            \\Wo🤓rld
        \\;
    ,
        \\const foo = "He😂llo\nWo🤓rld";
    );
    // Quotes
    try testConvertString(
        \\const foo = \\The<cursor> "cure"
        \\;
    ,
        \\const foo = "The \"cure\"";
    );
    try testConvertString(
        \\const foo = \\<cursor>\x49 \u{0033}
        \\            \\\n'
        \\            \\
        \\;
    ,
        \\const foo = "\\x49 \\u{0033}\n\\n'\n";
    );
    // The control characters TAB and CR are rejected by the grammar inside multi-line string literals,
    // except if CR is directly before NL.
    try testConvertString( // (force format)
        "const foo = \\\\<cursor>Hello\r\n;",
        \\const foo = "Hello";
    );
}

test "convert string literal to multiline" {
    try testConvertString(
        \\const foo = "He<cursor>llo\nWorld";
    ,
        \\const foo = \\Hello
        \\    \\World
        \\;
    );
    // Empty
    try testConvertString(
        \\const foo = "<cursor>";
    ,
        \\const foo = \\
        \\;
    );
    // In function
    try testConvertString(
        \\const x = foo("<cursor>bar\nbaz");
    ,
        \\const x = foo(\\bar
        \\    \\baz
        \\);
    );
}

test "convert string literal to multiline - cursor outside of string literal" {
    try testConvertString(
        \\const foo = <cursor> "hello";
    ,
        \\const foo =  "hello";
    );
    try testConvertString(
        \\const foo = <cursor>"hello";
    ,
        \\const foo = \\hello
        \\;
    );
    try testConvertString(
        \\const foo = "hello"<cursor>;
    ,
        \\const foo = \\hello
        \\;
    );
    // TODO
    // try testConvertString(
    //     \\const foo = "hello" <cursor>;
    // ,
    //     \\const foo = "hello" <cursor>;
    // );
}

test "convert string literal to multiline - escapes" {
    // Hex escapes
    try testConvertString(
        \\const foo = "<cursor>\x41\x42\x43";
    ,
        \\const foo = \\ABC
        \\;
    );
    // Hex escapes that form a unicode character in utf-8
    try testConvertString(
        \\const foo = "<cursor>\xE2\x9C\x85";
    ,
        \\const foo = \\✅
        \\;
    );
    // Newlines
    try testConvertString(
        \\const foo = "<cursor>\nhello\n\n";
    ,
        \\const foo = \\
        \\    \\hello
        \\    \\
        \\    \\
        \\;
    );
    // Quotes and slashes
    try testConvertString(
        \\const foo = "<cursor>A slash: \'\\\'";
    ,
        \\const foo = \\A slash: '\'
        \\;
    );
    // Unicode
    try testConvertString(
        \\const foo = "<cursor>Smile: \u{1F913}";
    ,
        \\const foo = \\Smile: 🤓
        \\;
    );
}

test "convert string literal to multiline - invalid" {
    // Invalid unicode
    try testConvertString(
        \\const foo = "<cursor>Smile: \u{1F9131}";
    ,
        \\const foo = "Smile: \u{1F9131}";
    );
    // Invalid utf-8
    try testConvertString(
        \\const foo = "<cursor>\xaa";
    ,
        \\const foo = "\xaa";
    );
    // Hex escaped unprintable character
    try testConvertString(
        \\const foo = "<cursor>\x7f";
    ,
        \\const foo = "\x7f";
    );
    // Tabs are invalid too
    try testConvertString(
        \\const foo = "<cursor>\tWe use tabs";
    ,
        \\const foo = "\tWe use tabs";
    );
    // A Multi-Line String Literals can't contain carriage returns
    try testConvertString(
        \\const foo = "<cursor>\r";
    ,
        \\const foo = "\r";
    );
    // Not in @import
    try testConvertString(
        \\const std = @import("<cursor>std");
    ,
        \\const std = @import("std");
    );
    // Not in test
    try testConvertString(
        \\test "<cursor>addition" { }
    ,
        \\test "addition" { }
    );
    // Not in extern
    try testConvertString(
        \\pub extern "<cursor>c" fn printf(format: [*:0]const u8) c_int;
    ,
        \\pub extern "c" fn printf(format: [*:0]const u8) c_int;
    );
}

test "move type into declaration - struct init" {
    try testRefactor(
        \\const Foo = struct { a: u32 = 0 };
        \\test {
        \\    var <cursor>foo = Foo{ .a = 1 };
        \\    _ = &foo;
        \\    const bar = Foo{};
        \\    _ = bar;
        \\}
        \\
    ,
        \\const Foo = struct { a: u32 = 0 };
        \\test {
        \\    var foo: Foo = .{ .a = 1 };
        \\    _ = &foo;
        \\    const bar = Foo{};
        \\    _ = bar;
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\const std = @import("std");
        \\const <cursor>gpa = std.heap.DebugAllocator(.{}){};
        \\
    ,
        \\const std = @import("std");
        \\const gpa: std.heap.DebugAllocator(.{}) = .{};
        \\
    , .@"refactor.rewrite", null);
}

test "move type into declaration - array init" {
    try testRefactor(
        \\test {
        \\    const <cursor>array = [_]u8{ 1, 2, 3 };
        \\    _ = array;
        \\}
        \\
    ,
        \\test {
        \\    const array: [3]u8 = .{ 1, 2, 3 };
        \\    _ = array;
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\const <cursor>array = [_:0]u8{ 1, 2 };
        \\const other = [4]u8{ 1, 2, 3, 4 };
        \\
    ,
        \\const array: [2:0]u8 = .{ 1, 2 };
        \\const other = [4]u8{ 1, 2, 3, 4 };
        \\
    , .@"refactor.rewrite", null);
}

test "move type into declaration - decl literal" {
    try testRefactor(
        \\const Foo = struct {
        \\    fn init() Foo {
        \\        return .{};
        \\    }
        \\    fn create() !Foo {
        \\        return .{};
        \\    }
        \\    const default: Foo = .{};
        \\};
        \\test {
        \\    const <cursor>a = Foo.init();
        \\    _ = a;
        \\}
        \\
    ,
        \\const Foo = struct {
        \\    fn init() Foo {
        \\        return .{};
        \\    }
        \\    fn create() !Foo {
        \\        return .{};
        \\    }
        \\    const default: Foo = .{};
        \\};
        \\test {
        \\    const a: Foo = .init();
        \\    _ = a;
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\const Foo = struct {
        \\    fn create() !Foo {
        \\        return .{};
        \\    }
        \\};
        \\test {
        \\    const <cursor>a = try Foo.create();
        \\    _ = a;
        \\}
        \\
    ,
        \\const Foo = struct {
        \\    fn create() !Foo {
        \\        return .{};
        \\    }
        \\};
        \\test {
        \\    const a: Foo = try .create();
        \\    _ = a;
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\const Foo = struct {
        \\    const default: Foo = .{};
        \\};
        \\const <cursor>a = Foo.default;
        \\
    ,
        \\const Foo = struct {
        \\    const default: Foo = .{};
        \\};
        \\const a: Foo = .default;
        \\
    , .@"refactor.rewrite", null);
    // the function does not return `Foo`
    try testRefactor(
        \\const Foo = struct {
        \\    fn count() u32 {
        \\        return 0;
        \\    }
        \\};
        \\const <cursor>a = Foo.count();
        \\
    ,
        \\const Foo = struct {
        \\    fn count() u32 {
        \\        return 0;
        \\    }
        \\};
        \\const a = Foo.count();
        \\
    , .@"refactor.rewrite", null);
}

test "move type into declaration - @as" {
    try testRefactor(
        \\const <cursor>a = @as(u32, 5);
        \\
    ,
        \\const a: u32 = 5;
        \\
    , .@"refactor.rewrite", null);
}

test "inline variable - function argument" {
    try testRefactor(
        \\const Foo = struct { a: u32 };
        \\fn bar(foo: Foo) void {
        \\    _ = foo;
        \\}
        \\test {
        \\    const <cursor>foo: Foo = .{ .a = 1 };
        \\    bar(foo);
        \\}
        \\
    ,
        \\const Foo = struct { a: u32 };
        \\fn bar(foo: Foo) void {
        \\    _ = foo;
        \\}
        \\test {
        \\    bar(.{ .a = 1 });
        \\}
        \\
    , .@"refactor.inline", null);
    // cursor on the usage
    try testRefactor(
        \\const Foo = struct { a: u32 };
        \\fn bar(foo: Foo) void {
        \\    _ = foo;
        \\}
        \\test {
        \\    const foo = Foo{ .a = 1 };
        \\    bar(<cursor>foo);
        \\}
        \\
    ,
        \\const Foo = struct { a: u32 };
        \\fn bar(foo: Foo) void {
        \\    _ = foo;
        \\}
        \\test {
        \\    bar(Foo{ .a = 1 });
        \\}
        \\
    , .@"refactor.inline", null);
}

test "inline variable - field and address of" {
    try testRefactor(
        \\const Color = struct { r: f32, g: f32 };
        \\const Attachment = struct { clear_value: Color };
        \\fn begin(attachments: []const Attachment) void {
        \\    _ = attachments;
        \\}
        \\test {
        \\    const <cursor>sky_blue: Color = .{ .r = 0.7, .g = 0.9 };
        \\    const attachments = [_]Attachment{.{
        \\        .clear_value = sky_blue,
        \\    }};
        \\    begin(&attachments);
        \\}
        \\
    ,
        \\const Color = struct { r: f32, g: f32 };
        \\const Attachment = struct { clear_value: Color };
        \\fn begin(attachments: []const Attachment) void {
        \\    _ = attachments;
        \\}
        \\test {
        \\    const attachments = [_]Attachment{.{
        \\        .clear_value = .{ .r = 0.7, .g = 0.9 },
        \\    }};
        \\    begin(&attachments);
        \\}
        \\
    , .@"refactor.inline", null);
    try testRefactor(
        \\const Attachment = struct { a: u32 };
        \\fn begin(attachments: []const Attachment) void {
        \\    _ = attachments;
        \\}
        \\test {
        \\    const <cursor>attachments = [_]Attachment{.{
        \\        .a = 1,
        \\    }};
        \\    begin(&attachments);
        \\}
        \\
    ,
        \\const Attachment = struct { a: u32 };
        \\fn begin(attachments: []const Attachment) void {
        \\    _ = attachments;
        \\}
        \\test {
        \\    begin(&[_]Attachment{.{
        \\        .a = 1,
        \\    }});
        \\}
        \\
    , .@"refactor.inline", null);
}

test "inline variable - parentheses and @as" {
    try testRefactor(
        \\fn foo(a: u32, b: u32) u32 {
        \\    const <cursor>sum = a + b;
        \\    return sum * 2 + sum;
        \\}
        \\
    ,
        \\fn foo(a: u32, b: u32) u32 {
        \\    return (a + b) * 2 + (a + b);
        \\}
        \\
    , .@"refactor.inline", null);
    try testRefactor(
        \\const Foo = struct { a: u32 };
        \\test {
        \\    const <cursor>foo: Foo = .{ .a = 1 };
        \\    _ = foo.a;
        \\}
        \\
    ,
        \\const Foo = struct { a: u32 };
        \\test {
        \\    _ = @as(Foo, .{ .a = 1 }).a;
        \\}
        \\
    , .@"refactor.inline", null);
    // side effects would be duplicated
    try testRefactor(
        \\fn bar() u32 {
        \\    return 1;
        \\}
        \\test {
        \\    const <cursor>foo = bar();
        \\    _ = foo + foo;
        \\}
        \\
    ,
        \\fn bar() u32 {
        \\    return 1;
        \\}
        \\test {
        \\    const foo = bar();
        \\    _ = foo + foo;
        \\}
        \\
    , .@"refactor.inline", null);
}

test "block to expression - labeled block with switch" {
    try testRefactor(
        \\test {
        \\    const x: u32 = 1;
        \\    const y: u32 = blk: {
        \\        <cursor>switch (x) {
        \\            0 => break :blk 1,
        \\            1 => {
        \\                break :blk 2;
        \\            },
        \\            else => unreachable,
        \\        }
        \\    };
        \\    _ = y;
        \\}
        \\
    ,
        \\test {
        \\    const x: u32 = 1;
        \\    const y: u32 = switch (x) {
        \\        0 => 1,
        \\        1 => 2,
        \\        else => unreachable,
        \\    };
        \\    _ = y;
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - nested labeled switch" {
    try testRefactor(
        \\fn foo(a: bool, b: bool) u32 {
        \\    return blk: {
        \\        <cursor>switch (a) {
        \\            true => {
        \\                switch (b) {
        \\                    true => break :blk 1,
        \\                    false => break :blk 2,
        \\                }
        \\            },
        \\            false => if (b) break :blk 3 else break :blk 4,
        \\        }
        \\    };
        \\}
        \\
    ,
        \\fn foo(a: bool, b: bool) u32 {
        \\    return switch (a) {
        \\        true => switch (b) {
        \\            true => 1,
        \\            false => 2,
        \\        },
        \\        false => if (b) 3 else 4,
        \\    };
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\test {
        \\    const value = <cursor>blk: {
        \\        break :blk 5;
        \\    };
        \\    _ = value;
        \\}
        \\
    ,
        \\test {
        \\    const value = 5;
        \\    _ = value;
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - early breaks" {
    try testRefactor(
        \\fn foo(a: ?u32, b: bool) u32 {
        \\    const value = blk: {
        \\        <cursor>if (a) |x| break :blk x;
        \\        if (b) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    return value;
        \\}
        \\
    ,
        \\fn foo(a: ?u32, b: bool) u32 {
        \\    const value = if (a) |x| x else if (b) 1 else 2;
        \\    return value;
        \\}
        \\
    , .@"refactor.rewrite", null);
    // statements without a value can not be converted
    try testRefactor(
        \\fn bar() void {}
        \\fn foo(b: bool) u32 {
        \\    const value = blk: {
        \\        <cursor>bar();
        \\        if (b) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    return value;
        \\}
        \\
    ,
        \\fn bar() void {}
        \\fn foo(b: bool) u32 {
        \\    const value = blk: {
        \\        bar();
        \\        if (b) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    return value;
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - assignments in branches" {
    try testRefactor(
        \\const Kind = enum { a, b, c };
        \\fn foo(kind: Kind, c: bool) u32 {
        \\    var <cursor>value: u32 = undefined;
        \\    switch (kind) {
        \\        .a => value = 1,
        \\        .b => {
        \\            value = if (c) 2 else 3;
        \\        },
        \\        .c => unreachable,
        \\    }
        \\    return value;
        \\}
        \\
    ,
        \\const Kind = enum { a, b, c };
        \\fn foo(kind: Kind, c: bool) u32 {
        \\    const value: u32 = switch (kind) {
        \\        .a => 1,
        \\        .b => if (c) 2 else 3,
        \\        .c => unreachable,
        \\    };
        \\    return value;
        \\}
        \\
    , .@"refactor.rewrite", null);
    try testRefactor(
        \\fn foo(c: bool) u32 {
        \\    var <cursor>value: u32 = undefined;
        \\    if (c) {
        \\        value = 1;
        \\    } else {
        \\        value = 2;
        \\    }
        \\    value += 1;
        \\    return value;
        \\}
        \\
    ,
        \\fn foo(c: bool) u32 {
        \\    var value: u32 = if (c) 1 else 2;
        \\    value += 1;
        \\    return value;
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - switch prong" {
    try testRefactor(
        \\fn foo(a: u32, b: u32) void {
        \\    switch (a) {
        \\        0 => <cursor>{
        \\            switch (b) {
        \\                0 => {},
        \\                else => {},
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
    ,
        \\fn foo(a: u32, b: u32) void {
        \\    switch (a) {
        \\        0 => switch (b) {
        \\            0 => {},
        \\            else => {},
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - cursor before the block on the same line" {
    // the block that opens on the cursor's line is preferred over the enclosing one
    try testRefactor(
        \\fn foo(a: u32, b: u32, c: u32) void {
        \\    switch (a) {
        \\        0 => {
        \\            switch (b) {
        \\<cursor>                0 => {
        \\                    switch (c) {
        \\                        0 => {},
        \\                        else => {},
        \\                    }
        \\                },
        \\                else => {},
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
    ,
        \\fn foo(a: u32, b: u32, c: u32) void {
        \\    switch (a) {
        \\        0 => {
        \\            switch (b) {
        \\                0 => switch (c) {
        \\                    0 => {},
        \\                    else => {},
        \\                },
        \\                else => {},
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "block to expression - if statement" {
    try testRefactor(
        \\fn bar() void {}
        \\fn foo(c: bool) void {
        \\    if (c) <cursor>{
        \\        bar();
        \\    }
        \\}
        \\
    ,
        \\fn bar() void {}
        \\fn foo(c: bool) void {
        \\    if (c) bar();
        \\}
        \\
    , .@"refactor.rewrite", null);
    // multiple statements can not be converted
    try testRefactor(
        \\fn bar() void {}
        \\fn foo(c: bool) void {
        \\    if (c) <cursor>{
        \\        bar();
        \\        bar();
        \\    }
        \\}
        \\
    ,
        \\fn bar() void {}
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        bar();
        \\        bar();
        \\    }
        \\}
        \\
    , .@"refactor.rewrite", null);
}

test "extract function - statements with return value" {
    try testRefactor(
        \\fn compute(a: u32, b: u32) u32 {
        \\    const sum: u32 = a + b;
        \\    <start>const doubled = sum * 2;
        \\    const tripled: u32 = doubled + sum + b;<end>
        \\    return tripled;
        \\}
        \\
    ,
        \\fn compute(a: u32, b: u32) u32 {
        \\    const sum: u32 = a + b;
        \\    const tripled: u32 = extracted(sum, b);
        \\    return tripled;
        \\}
        \\
        \\fn extracted(sum: u32, b: u32) u32 {
        \\    const doubled = sum * 2;
        \\    const tripled: u32 = doubled + sum + b;
        \\    return tripled;
        \\}
        \\
    , .@"refactor.extract", null);
}

test "extract function - mutated variable" {
    try testRefactor(
        \\const List = struct {
        \\    len: usize = 0,
        \\    fn append(list: *List) void {
        \\        list.len += 1;
        \\    }
        \\};
        \\test {
        \\    var count: u32 = 0;
        \\    var list: List = .{};
        \\    const step: u32 = 2;
        \\    <start>count += step;
        \\    list.append();<end>
        \\}
        \\
    ,
        \\const List = struct {
        \\    len: usize = 0,
        \\    fn append(list: *List) void {
        \\        list.len += 1;
        \\    }
        \\};
        \\test {
        \\    var count: u32 = 0;
        \\    var list: List = .{};
        \\    const step: u32 = 2;
        \\    extracted(&count, step, &list);
        \\}
        \\
        \\fn extracted(count: *u32, step: u32, list: *List) void {
        \\    count.* += step;
        \\    list.append();
        \\}
        \\
    , .@"refactor.extract", null);
}

test "extract function - block with try" {
    try testRefactor(
        \\const Scene = struct {
        \\    objects: u32 = 0,
        \\    fn lock(scene: *Scene) !void {
        \\        _ = scene;
        \\    }
        \\    fn update(scene: *Scene, dt: f32) !void {
        \\        <cursor>{
        \\            try scene.lock();
        \\            scene.objects += @intFromFloat(dt);
        \\        }
        \\    }
        \\};
        \\
    ,
        \\const Scene = struct {
        \\    objects: u32 = 0,
        \\    fn lock(scene: *Scene) !void {
        \\        _ = scene;
        \\    }
        \\    fn update(scene: *Scene, dt: f32) !void {
        \\        try extracted(scene, dt);
        \\    }
        \\
        \\    fn extracted(scene: *Scene, dt: f32) !void {
        \\        try scene.lock();
        \\        scene.objects += @intFromFloat(dt);
        \\    }
        \\};
        \\
    , .@"refactor.extract", null);
}

test "extract function - labeled block" {
    try testRefactor(
        \\const Animation = struct { name: []const u8 };
        \\fn find(animations: []const Animation, name: []const u8) Animation {
        \\    const animation: Animation = <cursor>blk: {
        \\        for (animations) |anim| {
        \\            if (anim.name.len == name.len) break :blk anim;
        \\        }
        \\        @panic("cannot find animation");
        \\    };
        \\    return animation;
        \\}
        \\
    ,
        \\const Animation = struct { name: []const u8 };
        \\fn find(animations: []const Animation, name: []const u8) Animation {
        \\    const animation: Animation = extracted(animations, name);
        \\    return animation;
        \\}
        \\
        \\fn extracted(animations: []const Animation, name: []const u8) Animation {
        \\    for (animations) |anim| {
        \\        if (anim.name.len == name.len) return anim;
        \\    }
        \\    @panic("cannot find animation");
        \\}
        \\
    , .@"refactor.extract", null);
}

test "extract function - multiple return values" {
    try testRefactor(
        \\test {
        \\    const base: u32 = 3;
        \\    <start>const a: u32 = base * 2;
        \\    var b: i64 = 4;<end>
        \\    b += a;
        \\}
        \\
    ,
        \\test {
        \\    const base: u32 = 3;
        \\    const a, var b = extracted(base);
        \\    b += a;
        \\}
        \\
        \\fn extracted(base: u32) struct { u32, i64 } {
        \\    const a: u32 = base * 2;
        \\    var b: i64 = 4;
        \\    return .{ a, b };
        \\}
        \\
    , .@"refactor.extract", null);
}

test "extract function - escaping control flow" {
    try testRefactor(
        \\fn foo(a: u32) u32 {
        \\    <start>if (a == 0) return 1;<end>
        \\    return 0;
        \\}
        \\
    ,
        \\fn foo(a: u32) u32 {
        \\    if (a == 0) return 1;
        \\    return 0;
        \\}
        \\
    , .@"refactor.extract", null);
}

fn testRefactor(before: []const u8, after: []const u8, kind: types.CodeAction.Kind, title: ?[]const u8) !void {
    try testDiagnostic(before, after, .{ .filter_kind = kind, .filter_title = title });
}

fn testAutofix(before: []const u8, after: []const u8) !void {
    try testDiagnostic(before, after, .{ .filter_kind = .@"source.fixAll", .want_zir = true }); // diagnostics come from std.zig.AstGen
    try testDiagnostic(before, after, .{ .filter_kind = .@"source.fixAll", .want_zir = false }); // diagnostics come from calling zig ast-check
}

fn testOrganizeImports(before: []const u8, after: []const u8) !void {
    try testDiagnostic(before, after, .{ .filter_kind = .@"source.organizeImports" });
}

fn testOrganizeImportsNoAction(source: []const u8) !void {
    var ctx: Context = try .init();
    defer ctx.deinit();

    const range: types.Range = .{
        .start = .{ .line = 0, .character = 0 },
        .end = offsets.indexToPosition(source, source.len, ctx.server.offset_encoding),
    };

    const uri = try ctx.addDocument(.{ .source = source });

    const params: types.CodeAction.Params = .{
        .textDocument = .{ .uri = uri.raw },
        .range = range,
        .context = .{
            .diagnostics = &.{},
            .only = &.{.@"source.organizeImports"},
        },
    };

    @setEvalBranchQuota(5000);
    const response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/codeAction", params) orelse return;

    if (response.len != 0) {
        std.debug.print("expected no organize-imports code action for already-organized source, got: {s}\n", .{response[0].code_action.title});
        return error.UnexpectedOrganizeImportsAction;
    }
}

fn testConvertString(before: []const u8, after: []const u8) !void {
    try testDiagnostic(before, after, .{ .filter_kind = .refactor });
}

fn testDiagnostic(
    before: []const u8,
    after: []const u8,
    options: struct {
        filter_kind: ?types.CodeAction.Kind = null,
        filter_title: ?[]const u8 = null,
        want_zir: bool = true,
    },
) !void {
    var ctx: Context = try .init();
    defer ctx.deinit();
    ctx.server.config_manager.config.prefer_ast_check_as_child_process = !options.want_zir;

    var phr = try helper.collectClearPlaceholders(allocator, before);
    defer phr.deinit(allocator);
    const placeholders = phr.locations.items(.new);
    const source = phr.new_source;

    const range: types.Range = switch (placeholders.len) {
        0 => .{
            .start = .{ .line = 0, .character = 0 },
            .end = offsets.indexToPosition(before, before.len, ctx.server.offset_encoding),
        },
        1 => blk: {
            const point = offsets.indexToPosition(before, placeholders[0].start, ctx.server.offset_encoding);
            break :blk .{ .start = point, .end = point };
        },
        2 => .{
            .start = offsets.indexToPosition(source, placeholders[0].start, ctx.server.offset_encoding),
            .end = offsets.indexToPosition(source, placeholders[1].start, ctx.server.offset_encoding),
        },
        else => unreachable,
    };

    const uri = try ctx.addDocument(.{ .source = source });
    const handle = ctx.server.document_store.getHandle(uri).?;

    const params: types.CodeAction.Params = .{
        .textDocument = .{ .uri = uri.raw },
        .range = range,
        .context = .{
            .diagnostics = &.{},
            .only = if (options.filter_kind) |kind| &.{kind} else null,
        },
    };

    @setEvalBranchQuota(5000);
    const response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/codeAction", params) orelse {
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    };

    var text_edits: std.ArrayList(types.TextEdit) = .empty;
    defer text_edits.deinit(allocator);

    for (response) |action| {
        const code_action: types.CodeAction = action.code_action;

        if (options.filter_kind) |kind| {
            // check that `types.CodeActionContext.only` is being respected
            const action_kind = code_action.kind.?;
            if (kind == .refactor and std.mem.startsWith(u8, @tagName(action_kind), "refactor.")) {
                // sub kinds are included when requesting `refactor` but are tested separately
                continue;
            }
            try std.testing.expectEqual(action_kind, kind);
        }
        if (options.filter_title) |title| {
            if (!std.mem.eql(u8, title, code_action.title)) continue;
        }

        const workspace_edit = code_action.edit.?;
        const changes = workspace_edit.changes.?.map;
        try std.testing.expectEqual(@as(usize, 1), changes.count());
        try std.testing.expect(changes.contains(uri.raw));

        try text_edits.appendSlice(allocator, changes.get(uri.raw).?);
    }

    const actual = try zls.diff.applyTextEdits(allocator, source, text_edits.items, ctx.server.offset_encoding);
    defer allocator.free(actual);
    try ctx.server.document_store.refreshLspSyncedDocument(uri, try allocator.dupeSentinel(u8, actual, 0));

    try zls.testing.expectEqualStrings(after, handle.tree.source);
}
