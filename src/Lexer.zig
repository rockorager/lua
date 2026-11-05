//! The Lua 5.5 lexer: source bytes to tokens, after llex.c in reference Lua
//! 5.5.1, with its error messages.
//!
//! The source is one `[:0]` slice. The sentinel lets the scanner test for
//! the end only where it reads a zero byte, which can also be an ordinary
//! character inside a string or comment. Names, numerals, and strings
//! without escapes or carriage returns are slices of the source; other
//! strings are decoded into one of two scratch buffers, so no token
//! allocates once the buffers have grown.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const number = @import("number.zig");

const Lexer = @This();

src: [:0]const u8,
/// Index of the next byte to scan.
pos: usize = 0,
/// The current line, counting from 1: after `next`, the line the token
/// ends on (llex.c's `linenumber`).
line: u32 = 1,
gpa: Allocator,
/// Decoded strings, used in turn: a token's decoded string stays valid
/// until `next` has been called twice more, so a parser can hold the
/// current token and one lookahead.
bufs: [2]std.ArrayList(u8) = .{ .empty, .empty },
next_buf: u1 = 0,
/// After `error.SyntaxError`, the message as llex.c words it, without the
/// "chunkname:line:" prefix that `luaG_addinfo` adds; `err_line` is the line.
err_msg: std.ArrayList(u8) = .empty,
err_line: u32 = 0,

/// Whether `global` is a reserved word. Reference Lua 5.5.1 builds with
/// `LUA_COMPAT_GLOBAL`, which keeps it a name, and its parser recognizes a
/// `global` declaration from the name and the token after it. With this
/// false, `.global` is never produced.
pub const global_is_reserved = false;

pub const Error = error{ SyntaxError, OutOfMemory };

/// A token's kind. A single-byte token is its own byte, including bytes
/// that are not Lua tokens (which the parser rejects); the others follow
/// llex.h's `ORDER RESERVED`.
pub const Kind = enum(u16) {
    hash = '#',
    percent = '%',
    amp = '&',
    lparen = '(',
    rparen = ')',
    star = '*',
    plus = '+',
    comma = ',',
    minus = '-',
    dot = '.',
    slash = '/',
    colon = ':',
    semicolon = ';',
    lt = '<',
    assign = '=',
    gt = '>',
    lbracket = '[',
    rbracket = ']',
    caret = '^',
    lbrace = '{',
    pipe = '|',
    rbrace = '}',
    tilde = '~',

    @"and" = 256,
    @"break",
    do,
    @"else",
    elseif,
    end,
    false,
    @"for",
    function,
    global,
    goto,
    @"if",
    in,
    local,
    nil,
    not,
    @"or",
    repeat,
    @"return",
    then,
    true,
    until,
    @"while",
    /// `//`
    idiv,
    /// `..`
    concat,
    /// `...`
    dots,
    /// `==`
    eq,
    /// `>=`
    ge,
    /// `<=`
    le,
    /// `~=`
    ne,
    /// `<<`
    shl,
    /// `>>`
    shr,
    /// `::`
    dbcolon,
    eos,
    float,
    int,
    name,
    string,
    _,
};

/// llex.c's `luaX_tokens`, indexed by `Kind` minus 256.
const kind_text = [_][]const u8{
    "and",      "break",  "do",       "else",      "elseif", "end",      "false", "for",
    "function", "global", "goto",     "if",        "in",     "local",    "nil",   "not",
    "or",       "repeat", "return",   "then",      "true",   "until",    "while", "//",
    "..",       "...",    "==",       ">=",        "<=",     "~=",       "<<",    ">>",
    "::",       "<eof>",  "<number>", "<integer>", "<name>", "<string>",
};

const reserved: std.StaticStringMap(Kind) = .initComptime(blk: {
    const first = @backingInt(Kind.@"and");
    const last = @backingInt(Kind.@"while");
    var words: [last - first + 1 - @intFromBool(!global_is_reserved)]struct { []const u8, Kind } = undefined;
    var n = 0;
    for (first..last + 1) |k| {
        if (k == @backingInt(Kind.global) and !global_is_reserved) continue;
        words[n] = .{ kind_text[k - 256], @fromBackingInt(@intCast(k)) };
        n += 1;
    }
    break :blk words;
});

pub const Token = struct {
    kind: Kind,
    /// The line the token ends on.
    line: u32,
    /// The token's bytes in the source: `src[start..end]`.
    start: usize,
    end: usize,
    data: Data,

    /// Selected by `kind`: `int` and `float` for numerals, `string` for
    /// names and strings (a string's contents, escapes decoded), `none`
    /// for the rest.
    pub const Data = union {
        none: void,
        int: i64,
        float: f64,
        string: []const u8,
    };
};

pub fn init(gpa: Allocator, src: [:0]const u8) Lexer {
    return .{ .gpa = gpa, .src = src };
}

pub fn deinit(lx: *Lexer) void {
    for (&lx.bufs) |*b| b.deinit(lx.gpa);
    lx.err_msg.deinit(lx.gpa);
    lx.* = undefined;
}

/// Scans the next token. At the end of the source it returns `.eos`, and
/// keeps returning it.
pub fn next(lx: *Lexer) Error!Token {
    const src = lx.src;
    var p = lx.pos;
    while (true) {
        const start = p;
        switch (src[p]) {
            '\n', '\r' => p = try lx.newline(p),
            ' ', '\t', 0x0b, 0x0c => p += 1,
            '-' => {
                if (src[p + 1] != '-') return lx.token(.minus, start, p + 1, .{ .none = {} });
                p += 2;
                if (src[p] == '[') {
                    if (longBracketLevel(src, p)) |level| {
                        p = (try lx.longBracket(p, level, .comment)).end;
                        continue;
                    }
                }
                while (true) : (p += 1) switch (src[p]) {
                    '\n', '\r' => break,
                    0 => if (p == src.len) break,
                    else => {},
                };
            },
            '[' => {
                if (longBracketLevel(src, p)) |level| {
                    const r = try lx.longBracket(p, level, .string);
                    return lx.token(.string, start, r.end, .{ .string = r.contents });
                }
                if (src[p + 1] == '=') {
                    var q = p + 1;
                    while (src[q] == '=') q += 1;
                    return lx.fail("invalid long string delimiter", .{}, .{ .text = &.{src[start..q]} });
                }
                return lx.token(.lbracket, start, p + 1, .{ .none = {} });
            },
            '=' => return lx.pair(start, .assign, '=', .eq),
            '<' => return if (src[p + 1] == '<')
                lx.token(.shl, start, p + 2, .{ .none = {} })
            else
                lx.pair(start, .lt, '=', .le),
            '>' => return if (src[p + 1] == '>')
                lx.token(.shr, start, p + 2, .{ .none = {} })
            else
                lx.pair(start, .gt, '=', .ge),
            '/' => return lx.pair(start, .slash, '/', .idiv),
            '~' => return lx.pair(start, .tilde, '=', .ne),
            ':' => return lx.pair(start, .colon, ':', .dbcolon),
            '"', '\'' => return lx.shortString(start),
            '.' => {
                if (src[p + 1] == '.') {
                    if (src[p + 2] == '.') return lx.token(.dots, start, p + 3, .{ .none = {} });
                    return lx.token(.concat, start, p + 2, .{ .none = {} });
                }
                if (isDigit(src[p + 1])) return lx.numeral(start, p + 1);
                return lx.token(.dot, start, p + 1, .{ .none = {} });
            },
            '0'...'9' => return lx.numeral(start, p),
            'A'...'Z', 'a'...'z', '_' => {
                var q = p + 1;
                while (isAlnum(src[q])) q += 1;
                const name = src[p..q];
                const kind = reserved.get(name) orelse .name;
                return lx.token(kind, start, q, .{ .string = name });
            },
            0 => {
                if (p == src.len) return lx.token(.eos, start, p, .{ .none = {} });
                return lx.token(@fromBackingInt(@intCast(0)), start, p + 1, .{ .none = {} });
            },
            else => |c| return lx.token(@fromBackingInt(@intCast(c)), start, p + 1, .{ .none = {} }),
        }
    }
}

fn token(lx: *Lexer, kind: Kind, start: usize, end: usize, data: Token.Data) Token {
    lx.pos = end;
    return .{ .kind = kind, .line = lx.line, .start = start, .end = end, .data = data };
}

/// `one`, or `two` when the next byte is `second`.
fn pair(lx: *Lexer, start: usize, one: Kind, second: u8, two: Kind) Token {
    if (lx.src[start + 1] == second) return lx.token(two, start, start + 2, .{ .none = {} });
    return lx.token(one, start, start + 1, .{ .none = {} });
}

/// Skips the newline at `p`, one of `\n`, `\r`, `\n\r`, or `\r\n`, and
/// counts the line. Returns the index after it.
fn newline(lx: *Lexer, p: usize) Error!usize {
    const src = lx.src;
    var q = p + 1;
    if ((src[q] == '\n' or src[q] == '\r') and src[q] != src[p]) q += 1;
    lx.line += 1;
    if (lx.line >= std.math.maxInt(i32)) return lx.fail("chunk has too many lines", .{}, .none);
    return q;
}

/// For `[` at `p`: the level of a long bracket `[==[` that opens there, or
/// null if there is none.
fn longBracketLevel(src: [:0]const u8, p: usize) ?usize {
    var q = p + 1;
    while (src[q] == '=') q += 1;
    return if (src[q] == '[') q - p - 1 else null;
}

/// Scans a long string or comment whose opening bracket of `level` starts
/// at `p`. A first newline is skipped, and every newline sequence in the
/// contents reads as `\n`.
fn longBracket(
    lx: *Lexer,
    p: usize,
    level: usize,
    what: enum { string, comment },
) Error!struct { end: usize, contents: []const u8 } {
    const src = lx.src;
    const first_line = lx.line;
    var q = p + level + 2;
    if (src[q] == '\n' or src[q] == '\r') q = try lx.newline(q);
    const contents_start = q;
    while (true) switch (src[q]) {
        ']' => {
            var r = q + 1;
            while (src[r] == '=') r += 1;
            if (src[r] == ']' and r - q - 1 == level) break;
            q = r;
        },
        '\n', '\r' => q = try lx.newline(q),
        0 => {
            if (q == src.len) return lx.fail(
                "unfinished long {s} (starting at line {d})",
                .{ @tagName(what), first_line },
                .eof,
            );
            q += 1;
        },
        else => q += 1,
    };
    const end = q + level + 2;
    const raw = src[contents_start..q];
    if (what == .comment or std.mem.findScalar(u8, raw, '\r') == null) return .{ .end = end, .contents = raw };
    const buf = lx.takeBuffer();
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        i += 1;
        if (c == '\n' or c == '\r') {
            if (i < raw.len and (raw[i] == '\n' or raw[i] == '\r') and raw[i] != c) i += 1;
            try buf.append(lx.gpa, '\n');
        } else {
            try buf.append(lx.gpa, c);
        }
    }
    return .{ .end = end, .contents = buf.items };
}

fn takeBuffer(lx: *Lexer) *std.ArrayList(u8) {
    const buf = &lx.bufs[lx.next_buf];
    lx.next_buf +%= 1;
    buf.clearRetainingCapacity();
    return buf;
}

/// Scans a string in quotes starting at `start`.
fn shortString(lx: *Lexer, start: usize) Error!Token {
    const src = lx.src;
    const del = src[start];
    var p = start + 1;
    // Most strings have no escapes and are a slice of the source.
    while (true) : (p += 1) {
        const c = src[p];
        if (c == del) return lx.token(.string, start, p + 1, .{ .string = src[start + 1 .. p] });
        switch (c) {
            '\\' => break,
            '\n', '\r' => return lx.fail("unfinished string", .{}, .{ .text = &.{src[start..p]} }),
            0 => if (p == src.len) return lx.fail("unfinished string", .{}, .eof),
            else => {},
        }
    }

    const buf = lx.takeBuffer();
    const gpa = lx.gpa;
    try buf.appendSlice(gpa, src[start + 1 .. p]);
    while (true) {
        const run = p;
        while (true) : (p += 1) switch (src[p]) {
            '\\', '\n', '\r', 0 => break,
            else => if (src[p] == del) break,
        };
        try buf.appendSlice(gpa, src[run..p]);
        switch (src[p]) {
            '\\' => {},
            '\n', '\r' => {
                const near: Near = .{ .text = &.{ src[start .. start + 1], buf.items } };
                return lx.fail("unfinished string", .{}, near);
            },
            0 => {
                if (p == src.len) return lx.fail("unfinished string", .{}, .eof);
                try buf.append(gpa, 0);
                p += 1;
                continue;
            },
            else => break, // the closing delimiter
        }
        const esc = p;
        p += 1;
        switch (src[p]) {
            'a' => try buf.append(gpa, 0x07),
            'b' => try buf.append(gpa, 0x08),
            'f' => try buf.append(gpa, 0x0c),
            'n' => try buf.append(gpa, '\n'),
            'r' => try buf.append(gpa, '\r'),
            't' => try buf.append(gpa, '\t'),
            'v' => try buf.append(gpa, 0x0b),
            '\\', '"', '\'' => try buf.append(gpa, src[p]),
            'x' => {
                const msg = "hexadecimal digit expected";
                const hi = hexValue(src[p + 1]) orelse return lx.escapeError(msg, start, esc, p + 1);
                const lo = hexValue(src[p + 2]) orelse return lx.escapeError(msg, start, esc, p + 2);
                try buf.append(gpa, hi << 4 | lo);
                p += 2;
            },
            'u' => {
                var q = p + 1;
                if (src[q] != '{') return lx.escapeError("missing '{'", start, esc, q);
                q += 1;
                var r: u32 = hexValue(src[q]) orelse return lx.escapeError("hexadecimal digit expected", start, esc, q);
                q += 1;
                while (hexValue(src[q])) |d| : (q += 1) {
                    if (r > 0x7FFF_FFFF >> 4) return lx.escapeError("UTF-8 value too large", start, esc, q);
                    r = r << 4 | d;
                }
                if (src[q] != '}') return lx.escapeError("missing '}'", start, esc, q);
                var utf8: [6]u8 = undefined;
                try buf.appendSlice(gpa, utf8Escape(&utf8, r));
                p = q;
            },
            '\n', '\r' => {
                p = try lx.newline(p);
                try buf.append(gpa, '\n');
                continue;
            },
            'z' => {
                p += 1;
                while (isSpace(src[p])) {
                    if (src[p] == '\n' or src[p] == '\r') p = try lx.newline(p) else p += 1;
                }
                continue;
            },
            '0'...'9' => {
                var q = p;
                var r: u32 = 0;
                while (q < p + 3 and isDigit(src[q])) : (q += 1) r = r * 10 + (src[q] - '0');
                if (r > 255) return lx.escapeError("decimal escape too large", start, esc, q);
                try buf.append(gpa, @intCast(r));
                p = q;
                continue;
            },
            else => {
                // The end of the source reports "unfinished string" next.
                if (p == src.len) continue;
                return lx.escapeError("invalid escape sequence", start, esc, p);
            },
        }
        p += 1;
    }
    return lx.token(.string, start, p + 1, .{ .string = buf.items });
}

/// An error in the escape at `esc`, found at `cur`. llex.c's buffer holds
/// the delimiter, the contents decoded so far, and the escape's raw bytes
/// through `cur` (unless that is the end), which is the `near` text.
fn escapeError(lx: *Lexer, msg: []const u8, start: usize, esc: usize, cur: usize) Error {
    const src = lx.src;
    const end = if (cur < src.len) cur + 1 else cur;
    const buf = lx.bufs[lx.next_buf +% 1].items;
    return lx.fail("{s}", .{msg}, .{ .text = &.{ src[start .. start + 1], buf, src[esc..end] } });
}

/// `luaO_utf8esc`: the code point `x` < 2^31 in UTF-8's original form, up
/// to six bytes.
fn utf8Escape(out: *[6]u8, x_: u32) []const u8 {
    var x = x_;
    if (x < 0x80) {
        out[5] = @intCast(x);
        return out[5..];
    }
    var n: usize = 1;
    var mfb: u32 = 0x3f; // the largest value that fits in the first byte
    while (true) {
        out[6 - n] = @intCast(0x80 | (x & 0x3f));
        n += 1;
        x >>= 6;
        mfb >>= 1;
        if (x <= mfb) break;
    }
    out[6 - n] = @intCast((~mfb << 1 | x) & 0xff);
    return out[6 - n ..];
}

/// Scans a numeral starting at `start`, whose first digit is at `first`
/// (after a leading `.`). Like `read_numeral`, it takes the longest run of
/// hex digits, points, and exponents with their signs, plus one touching
/// letter, then lets `number.parse` reject a malformed one.
fn numeral(lx: *Lexer, start: usize, first: usize) Error!Token {
    const src = lx.src;
    var p = first + 1;
    var exp: u8 = 'e';
    if (src[first] == '0' and (src[p] | 0x20) == 'x') {
        p += 1;
        exp = 'p';
    }
    while (true) {
        const c = src[p];
        if ((c | 0x20) == exp) {
            p += 1;
            if (src[p] == '+' or src[p] == '-') p += 1;
        } else if (hexValue(c) != null or c == '.') {
            p += 1;
        } else break;
    }
    if (isAlpha(src[p])) p += 1;
    const text = src[start..p];
    const n = number.parse(text) orelse return lx.fail("malformed number", .{}, .{ .text = &.{text} });
    return switch (n) {
        .int => |i| lx.token(.int, start, p, .{ .int = i }),
        .float => |f| lx.token(.float, start, p, .{ .float = f }),
    };
}

const Near = union(enum) {
    none,
    eof,
    /// Pieces of llex.c's token buffer, which `%s` cuts at a zero byte.
    text: []const []const u8,
};

fn fail(lx: *Lexer, comptime fmt: []const u8, args: anytype, near: Near) Error {
    const gpa = lx.gpa;
    lx.err_line = lx.line;
    lx.err_msg.clearRetainingCapacity();
    try lx.err_msg.print(gpa, fmt, args);
    switch (near) {
        .none => {},
        .eof => try lx.err_msg.appendSlice(gpa, " near <eof>"),
        .text => |parts| {
            try lx.err_msg.appendSlice(gpa, " near '");
            for (parts) |part| {
                const cut = std.mem.findScalar(u8, part, 0);
                try lx.err_msg.appendSlice(gpa, part[0 .. cut orelse part.len]);
                if (cut != null) break;
            }
            try lx.err_msg.append(gpa, '\'');
        },
    }
    return error.SyntaxError;
}

/// The message of the last `error.SyntaxError`.
pub fn errorMessage(lx: *const Lexer) []const u8 {
    return lx.err_msg.items;
}

/// Writes a kind as `luaX_token2str` does, for messages such as "'end'
/// expected": `'+'`, `'<\1>'` for an unprintable byte, `'=='`, `'and'`,
/// `<eof>`, `<name>`.
pub fn writeKind(w: *Writer, kind: Kind) Writer.Error!void {
    const k = @backingInt(kind);
    if (k < 256) {
        const c: u8 = @intCast(k);
        if (c >= ' ' and c < 0x7f) return w.print("'{c}'", .{c});
        return w.print("'<\\{d}>'", .{c});
    }
    const text = kind_text[k - 256];
    if (@backingInt(kind) < @backingInt(Kind.eos)) return w.print("'{s}'", .{text});
    return w.writeAll(text);
}

/// Writes the token a syntax error is "near", as `txtToken` does: a name
/// or numeral as its source text and a string with its delimiters and
/// decoded contents, in quotes and cut at a zero byte; anything else as
/// `writeKind`. A decoded string must still be valid (see `bufs`).
pub fn writeNear(lx: *const Lexer, w: *Writer, tok: Token) Writer.Error!void {
    switch (tok.kind) {
        .name, .int, .float => return w.print("'{s}'", .{lx.src[tok.start..tok.end]}),
        .string => {
            const src = lx.src;
            const s = tok.data.string;
            // `"`, `'`, or `[==[`, and the matching close.
            const delim_len = if (src[tok.start] == '[') longBracketLevel(src, tok.start).? + 2 else 1;
            const open = src[tok.start..][0..delim_len];
            const close = src[tok.end - delim_len .. tok.end];
            try w.print("'{s}", .{open});
            if (std.mem.findScalar(u8, s, 0)) |cut| {
                try w.print("{s}'", .{s[0..cut]});
            } else {
                try w.print("{s}{s}'", .{ s, close });
            }
        },
        else => return writeKind(w, tok.kind),
    }
}

fn isDigit(c: u8) bool {
    return c -% '0' < 10;
}

/// `lislalpha`: an ASCII letter or `_`.
fn isAlpha(c: u8) bool {
    return (c | 0x20) -% 'a' < 26 or c == '_';
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

/// `lisspace`: the C locale's whitespace.
fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests. Expected messages, lines, and string values come from reference Lua
// 5.5.1: `load("local x = " .. src, "=x")` and `load("return " .. src)()`.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectKinds(src: [:0]const u8, kinds: []const Kind) !void {
    var lx: Lexer = .init(testing.allocator, src);
    defer lx.deinit();
    for (kinds) |k| try testing.expectEqual(k, (try lx.next()).kind);
    try testing.expectEqual(Kind.eos, (try lx.next()).kind);
    try testing.expectEqual(Kind.eos, (try lx.next()).kind);
}

test "every operator and reserved word, and global as a name" {
    try expectKinds(
        "+ - * / // % ^ # & ~ | << >> < <= > >= = == ~= ( ) { } [ ] :: ; : , . .. ...",
        &.{
            .plus,      .minus, .star,   .slash,  .idiv,   .percent, .caret,    .hash,     .amp,
            .tilde,     .pipe,  .shl,    .shr,    .lt,     .le,      .gt,       .ge,       .assign,
            .eq,        .ne,    .lparen, .rparen, .lbrace, .rbrace,  .lbracket, .rbracket, .dbcolon,
            .semicolon, .colon, .comma,  .dot,    .concat, .dots,
        },
    );
    try expectKinds(
        "and break do else elseif end false for function goto if in local nil not or " ++
            "repeat return then true until while global _ x1 And",
        &.{
            .@"and", .@"break", .do,    .@"else",  .elseif, .end,  .false, .@"for", .function,
            .goto,   .@"if",    .in,    .local,    .nil,    .not,  .@"or", .repeat, .@"return",
            .then,   .true,     .until, .@"while", .name,   .name, .name,  .name,
        },
    );
    // Bytes that are not Lua tokens come back as themselves.
    try expectKinds("$@\x00\x80", &.{
        @fromBackingInt('$'), @fromBackingInt('@'), @fromBackingInt(0), @fromBackingInt(0x80),
    });
    // Comments of every form, and a short comment at the end.
    try expectKinds("--x\n1 --[==[ ]] ]=] \n]==] 2 --[==x\n 3 --[[]]4--", &.{ .int, .int, .int, .int });
}

test "numerals are integers or floats as tonumber reads them" {
    var lx: Lexer = .init(testing.allocator, "3 0xff .5 3. 1e2 0x1p4 9223372036854775808 0xffffffffffffffff 3..2");
    defer lx.deinit();
    try testing.expectEqual(3, (try lx.next()).data.int);
    try testing.expectEqual(255, (try lx.next()).data.int);
    try testing.expectEqual(0.5, (try lx.next()).data.float);
    try testing.expectEqual(3.0, (try lx.next()).data.float);
    try testing.expectEqual(100.0, (try lx.next()).data.float);
    try testing.expectEqual(16.0, (try lx.next()).data.float);
    try testing.expectEqual(0x1p63, (try lx.next()).data.float);
    try testing.expectEqual(-1, (try lx.next()).data.int);
    // `3..2` is one malformed numeral, as in the reference.
    try testing.expectError(error.SyntaxError, lx.next());
    try testing.expectEqualStrings("malformed number near '3..2'", lx.errorMessage());
}

test "strings decode every escape" {
    const src =
        "'a\\tb\\65\\x41\\u{48}\\u{7FF}\\u{10FFFF}\\u{7FFFFFFF}\\z \n  c\\\nd\\\r\ne\\0f' " ++
        "[==[\r\nx]=]\r\n\ry\n\rz]==] [[\nfirst\n\rnewline]] \"plain\"";
    var lx: Lexer = .init(testing.allocator, src);
    defer lx.deinit();
    const a = try lx.next();
    const b = try lx.next();
    // Both were decoded, into the two scratch buffers, and both are valid.
    try testing.expectEqualStrings(
        "a\tbAAH\xdf\xbf\xf4\x8f\xbf\xbf\xfd\xbf\xbf\xbf\xbf\xbfc\nd\ne\x00f",
        a.data.string,
    );
    try testing.expectEqualStrings("x]=]\n\ny\nz", b.data.string);
    const c = try lx.next();
    const d = try lx.next();
    try testing.expectEqualStrings("first\nnewline", c.data.string);
    // A string with nothing to decode is a slice of the source.
    try testing.expectEqualStrings("plain", d.data.string);
    try testing.expect(d.data.string.ptr == src[d.start + 1 ..].ptr);
    try testing.expectEqual(4, a.line);
    try testing.expectEqual(8, b.line);
}

test "lines count every newline sequence" {
    var lx: Lexer = .init(testing.allocator, "a\nb\r\nc\n\rd\re\n\nf --[[\n]] g [[\r\n\r\n]] h 'x\\z\n\n' i");
    defer lx.deinit();
    const lines = [_]u32{ 1, 2, 3, 4, 5, 7, 8, 10, 10, 12, 12 };
    for (lines) |line| try testing.expectEqual(line, (try lx.next()).line);
}

test "errors match llex.c's messages, near text, and lines" {
    const cases = [_]struct { [:0]const u8, []const u8, u32 }{
        .{ "3x", "malformed number near '3x'", 1 },
        .{ "0x", "malformed number near '0x'", 1 },
        .{ "1e+", "malformed number near '1e+'", 1 },
        .{ ".5_", "malformed number near '.5_'", 1 },
        .{ "0x1pg", "malformed number near '0x1pg'", 1 },
        .{ "\"abc", "unfinished string near <eof>", 1 },
        .{ "\"abc\ndef\"", "unfinished string near '\"abc'", 1 },
        .{ "'a\\q'", "invalid escape sequence near ''a\\q'", 1 },
        .{ "'\\xg1'", "hexadecimal digit expected near ''\\xg'", 1 },
        .{ "'\\x5'", "hexadecimal digit expected near ''\\x5''", 1 },
        .{ "'\\u{110000000}'", "UTF-8 value too large near ''\\u{110000000'", 1 },
        .{ "'\\u{80000000}'", "UTF-8 value too large near ''\\u{80000000'", 1 },
        .{ "'\\u41'", "missing '{' near ''\\u4'", 1 },
        .{ "'\\u{}'", "hexadecimal digit expected near ''\\u{}'", 1 },
        .{ "'\\u{41'", "missing '}' near ''\\u{41''", 1 },
        .{ "'\\256'", "decimal escape too large near ''\\256''", 1 },
        .{ "'\\2564'", "decimal escape too large near ''\\2564'", 1 },
        // The near text stops at a zero byte, decoded or not.
        .{ "'a\\0b\\q'", "invalid escape sequence near ''a'", 1 },
        .{ "'\\z  \n\n  \\q'", "invalid escape sequence near ''\\q'", 3 },
        .{ "'abc\\", "unfinished string near <eof>", 1 },
        // Earlier escapes appear decoded.
        .{ "'\\9x\\xZZ'", "hexadecimal digit expected near ''\tx\\xZ'", 1 },
        .{ "'\\\r\n\\\n\\q'", "invalid escape sequence near ''\n\n\\q'", 3 },
        .{ "[==[ abc", "unfinished long string (starting at line 1) near <eof>", 1 },
        .{ "[=[\n\n", "unfinished long string (starting at line 1) near <eof>", 3 },
        .{ "--[[ x\n\n", "unfinished long comment (starting at line 1) near <eof>", 3 },
        .{ "[==", "invalid long string delimiter near '[=='", 1 },
        .{ "[=x", "invalid long string delimiter near '[='", 1 },
    };
    for (cases) |c| {
        var lx: Lexer = .init(testing.allocator, c[0]);
        defer lx.deinit();
        try testing.expectError(error.SyntaxError, lx.next());
        try testing.expectEqualStrings(c[1], lx.errorMessage());
        try testing.expectEqual(c[2], lx.err_line);
    }
}

test "writeKind and writeNear word tokens as the reference does" {
    var lx: Lexer = .init(testing.allocator, "x 0x10 'a\\nb' [==[c]==] '\\0z' == end + \x01");
    defer lx.deinit();
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    while (true) {
        const t = try lx.next();
        try lx.writeNear(&w, t);
        if (t.kind == .eos) break;
        try w.writeByte(' ');
    }
    try writeKind(&w, .name);
    try testing.expectEqualStrings(
        "'x' '0x10' ''a\nb'' '[==[c]==]' ''' '==' 'end' '+' '<\\1>' <eof><name>",
        w.buffered(),
    );
}

test "every file of the official suite lexes" {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "test/lua-5.5.1-tests", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const gpa = testing.allocator;
        const src = try dir.readFileAllocOptions(testing.io, entry.name, gpa, .limited(1 << 20), .of(u8), 0);
        defer testing.allocator.free(src);
        var lx: Lexer = .init(testing.allocator, src);
        defer lx.deinit();
        while (true) {
            const t = lx.next() catch |err| {
                std.debug.print("{s}:{d}: {s}\n", .{ entry.name, lx.err_line, lx.errorMessage() });
                return err;
            };
            if (t.kind == .eos) {
                try testing.expectEqual(std.mem.count(u8, src, "\n") + 1, t.line);
                break;
            }
        }
        files += 1;
    }
    try testing.expect(files >= 33);
}
