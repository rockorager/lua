//! Lua patterns, as the reference manual's §6.5.1 defines them: the matching
//! engine behind `string.find`, `string.match`, `string.gmatch`, and
//! `string.gsub`.
//!
//! The engine works over byte slices and knows nothing of Lua values. Offsets
//! are 0-based byte indices into the subject; position captures report the
//! 1-based Lua index, as `()` does in Lua. Matching never allocates: a
//! `Matcher` holds its captures inline, and recursion is bounded by the same
//! depth limit the reference uses. Errors are `error.PatternError`, with the
//! reference's message in `Matcher.diag`.

const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

/// The most captures one pattern may hold (`LUA_MAXCAPTURES`).
pub const max_captures = 32;

/// The deepest `match` may recurse before "pattern too complex" (`MAXCCALLS`).
const max_depth = 200;

const esc = '%';

/// The bytes that make a pattern more than a plain string (`SPECIALS`).
const specials = "^$*+?.([%-";

/// The only error the engine raises; the message is in `Matcher.diag`.
pub const Error = error{PatternError};

/// The message of the last `error.PatternError`, held inline so that raising
/// it does not allocate.
pub const Diagnostic = struct {
    len: u8 = 0,
    buf: [64]u8 = undefined,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn fail(d: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
        const s = std.mem.print(&d.buf, fmt, args) catch unreachable;
        d.len = @intCast(s.len);
        return error.PatternError;
    }
};

/// A match: the bytes `src[start..end]`.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// One capture's value: a substring, or the 1-based position a `()` capture
/// recorded.
pub const Capture = union(enum) {
    string: []const u8,
    position: usize,
};

const cap_unfinished: isize = -1;
const cap_position: isize = -2;

/// The state of matching one pattern against one subject. Initialize it once
/// per call; each match attempt resets the captures.
pub const Matcher = struct {
    src: []const u8,
    /// The pattern without its anchor.
    pattern: []const u8,
    /// Whether the pattern began with `^`, so only the first position is tried.
    anchor: bool,
    /// The number of captures, finished or not, of the last match.
    level: u8 = 0,
    depth: u32 = max_depth,
    captures: [max_captures]struct { start: usize, len: isize } = undefined,
    diag: Diagnostic = .{},

    /// A matcher for `string.find`, `string.match`, and `string.gsub`, where a
    /// leading `^` anchors the match.
    pub fn init(src: []const u8, pattern: []const u8) Matcher {
        const anchor = pattern.len > 0 and pattern[0] == '^';
        return .{
            .src = src,
            .pattern = if (anchor) pattern[1..] else pattern,
            .anchor = anchor,
        };
    }

    /// `init` in place, for a matcher that does not live on the stack: the
    /// fields one by one, so the captures are not copied or filled.
    pub fn reset(m: *Matcher, src: []const u8, pattern: []const u8) void {
        const anchor = pattern.len > 0 and pattern[0] == '^';
        m.src = src;
        m.pattern = if (anchor) pattern[1..] else pattern;
        m.anchor = anchor;
        m.level = 0;
        m.depth = max_depth;
        m.diag = .{};
    }

    /// The number of values `string.match`, `string.gmatch`, and a gsub
    /// callback receive: the captures, or the whole match when there are none.
    /// (`string.find` returns `level` captures after the two positions.)
    pub fn resultCount(m: *const Matcher) usize {
        return if (m.level == 0) 1 else m.level;
    }

    /// Capture `i` (0-based) of the last match, which spanned `whole`. With no
    /// captures, capture 0 is the whole match (`get_onecapture`).
    pub fn capture(m: *Matcher, i: usize, whole: Span) Error!Capture {
        if (i >= m.level) {
            if (i != 0) return m.diag.fail("invalid capture index %{d}", .{i + 1});
            return .{ .string = m.src[whole.start..whole.end] };
        }
        const c = m.captures[i];
        if (c.len == cap_unfinished) return m.diag.fail("unfinished capture", .{});
        if (c.len == cap_position) return .{ .position = c.start + 1 };
        return .{ .string = m.src[c.start..][0..@intCast(c.len)] };
    }

    /// Try to match the pattern starting exactly at `s`; return where the
    /// match ends.
    pub fn matchAt(m: *Matcher, s: usize) Error!?usize {
        m.level = 0;
        m.depth = max_depth;
        return m.match(s, 0);
    }

    fn pat(m: *const Matcher, p: usize) u8 {
        return if (p < m.pattern.len) m.pattern[p] else 0;
    }

    /// The index just past the single-character class at `p` (`classend`).
    fn classEnd(m: *Matcher, p_start: usize) Error!usize {
        var p = p_start;
        const c = m.pattern[p];
        p += 1;
        switch (c) {
            esc => {
                if (p >= m.pattern.len) return m.diag.fail("malformed pattern (ends with '%')", .{});
                return p + 1;
            },
            '[' => {
                if (m.pat(p) == '^') p += 1;
                while (true) { // look for a ']'
                    if (p >= m.pattern.len) return m.diag.fail("malformed pattern (missing ']')", .{});
                    const cc = m.pattern[p];
                    p += 1;
                    if (cc == esc and p < m.pattern.len) p += 1; // skip escapes such as '%]'
                    if (m.pat(p) == ']') break;
                }
                return p + 1;
            },
            else => return p,
        }
    }

    /// Whether `c` is in the set `[...]` that spans `pattern[p..ec]`, where
    /// `p` is the '[' and `ec` the closing ']'.
    fn matchBracket(m: *const Matcher, c: u8, p_start: usize, ec: usize) bool {
        var p = p_start;
        var sig = true;
        if (m.pattern[p + 1] == '^') {
            sig = false;
            p += 1;
        }
        p += 1;
        while (p < ec) : (p += 1) {
            const pc = m.pattern[p];
            if (pc == esc) {
                p += 1;
                if (matchClass(c, m.pattern[p])) return sig;
            } else if (m.pattern[p + 1] == '-' and p + 2 < ec) {
                p += 2;
                if (pc <= c and c <= m.pattern[p]) return sig;
            } else if (pc == c) return sig;
        }
        return !sig;
    }

    fn singleMatch(m: *const Matcher, s: usize, p: usize, ep: usize) bool {
        if (s >= m.src.len) return false;
        const c = m.src[s];
        return switch (m.pattern[p]) {
            '.' => true,
            esc => matchClass(c, m.pattern[p + 1]),
            '[' => m.matchBracket(c, p, ep - 1),
            else => |pc| pc == c,
        };
    }

    fn matchBalance(m: *Matcher, s: usize, p: usize) Error!?usize {
        if (p + 1 >= m.pattern.len) return m.diag.fail("malformed pattern (missing arguments to '%b')", .{});
        const b = m.pattern[p];
        const e = m.pattern[p + 1];
        if (s >= m.src.len or m.src[s] != b) return null;
        var cont: usize = 1;
        var i = s + 1;
        while (i < m.src.len) : (i += 1) {
            const c = m.src[i];
            if (c == e) {
                cont -= 1;
                if (cont == 0) return i + 1;
            } else if (c == b) cont += 1;
        }
        return null; // the subject ends out of balance
    }

    fn maxExpand(m: *Matcher, s: usize, p: usize, ep: usize) Error!?usize {
        var i: usize = 0;
        while (m.singleMatch(s + i, p, ep)) i += 1;
        // Try the rest of the pattern with the most repetitions, then fewer.
        while (true) {
            if (try m.match(s + i, ep + 1)) |res| return res;
            if (i == 0) return null;
            i -= 1;
        }
    }

    fn minExpand(m: *Matcher, s_start: usize, p: usize, ep: usize) Error!?usize {
        var s = s_start;
        while (true) {
            if (try m.match(s, ep + 1)) |res| return res;
            if (!m.singleMatch(s, p, ep)) return null;
            s += 1; // try with one more repetition
        }
    }

    fn startCapture(m: *Matcher, s: usize, p: usize, what: isize) Error!?usize {
        const level = m.level;
        if (level >= max_captures) return m.diag.fail("too many captures", .{});
        m.captures[level] = .{ .start = s, .len = what };
        m.level = level + 1;
        const res = try m.match(s, p);
        if (res == null) m.level -= 1; // undo the capture
        return res;
    }

    fn endCapture(m: *Matcher, s: usize, p: usize) Error!?usize {
        const l = try m.captureToClose();
        m.captures[l].len = @intCast(s - m.captures[l].start);
        const res = try m.match(s, p);
        if (res == null) m.captures[l].len = cap_unfinished; // undo the close
        return res;
    }

    fn captureToClose(m: *Matcher) Error!usize {
        var level: usize = m.level;
        while (level > 0) {
            level -= 1;
            if (m.captures[level].len == cap_unfinished) return level;
        }
        return m.diag.fail("invalid pattern capture", .{});
    }

    /// A back-reference `%1`-`%9` (`match_capture`); `digit` is the byte after
    /// the '%'.
    fn matchCapture(m: *Matcher, s: usize, digit: u8) Error!?usize {
        const l = @as(isize, digit) - '1';
        if (l < 0 or l >= m.level or m.captures[@intCast(l)].len == cap_unfinished)
            return m.diag.fail("invalid capture index %{d}", .{l + 1});
        const c = m.captures[@intCast(l)];
        if (c.len == cap_position) return null; // as the reference: its length is huge
        const len: usize = @intCast(c.len);
        if (m.src.len - s >= len and std.mem.eql(u8, m.src[c.start..][0..len], m.src[s..][0..len]))
            return s + len;
        return null;
    }

    /// Match `pattern[p..]` against `src[s..]`; return where the match ends.
    fn match(m: *Matcher, s_start: usize, p_start: usize) Error!?usize {
        if (m.depth == 0) return m.diag.fail("pattern too complex", .{});
        m.depth -= 1;
        defer m.depth += 1;
        var s = s_start;
        var p = p_start;
        // Tail calls in the reference become iterations of this loop.
        while (p < m.pattern.len) {
            dflt: {
                switch (m.pattern[p]) {
                    '(' => {
                        if (m.pat(p + 1) == ')') return m.startCapture(s, p + 2, cap_position);
                        return m.startCapture(s, p + 1, cap_unfinished);
                    },
                    ')' => return m.endCapture(s, p + 1),
                    '$' => {
                        if (p + 1 != m.pattern.len) break :dflt; // not the last byte: a literal
                        return if (s == m.src.len) s else null;
                    },
                    esc => switch (m.pat(p + 1)) {
                        'b' => {
                            s = try m.matchBalance(s, p + 2) orelse return null;
                            p += 4;
                            continue;
                        },
                        'f' => {
                            p += 2;
                            if (m.pat(p) != '[') return m.diag.fail("missing '[' after '%f' in pattern", .{});
                            const ep = try m.classEnd(p);
                            const prev: u8 = if (s == 0) 0 else m.src[s - 1];
                            const cur: u8 = if (s < m.src.len) m.src[s] else 0;
                            if (!m.matchBracket(prev, p, ep - 1) and m.matchBracket(cur, p, ep - 1)) {
                                p = ep;
                                continue;
                            }
                            return null;
                        },
                        '0'...'9' => |d| {
                            s = try m.matchCapture(s, d) orelse return null;
                            p += 2;
                            continue;
                        },
                        else => break :dflt,
                    },
                    else => break :dflt,
                }
            }
            // A single-character class with an optional quantifier.
            const ep = try m.classEnd(p);
            const q = m.pat(ep);
            if (!m.singleMatch(s, p, ep)) {
                if (q == '*' or q == '?' or q == '-') { // accepts empty
                    p = ep + 1;
                    continue;
                }
                return null; // '+' or no quantifier
            }
            switch (q) {
                '?' => {
                    if (try m.match(s + 1, ep + 1)) |res| return res;
                    p = ep + 1;
                },
                '+' => return m.maxExpand(s + 1, p, ep),
                '*' => return m.maxExpand(s, p, ep),
                '-' => return m.minExpand(s, p, ep),
                else => {
                    s += 1;
                    p = ep;
                },
            }
        }
        return s;
    }
};

/// Whether byte `c` is in the class named by `cl`, the byte after a '%'
/// (`match_class`). Classes follow the C locale.
fn matchClass(c: u8, cl: u8) bool {
    const bit = class_bit[cl];
    if (bit == 0) return cl == c;
    const res = ctype[c] & bit != 0;
    return if (cl >= 'a') res else !res;
}

const class_bit: [256]u16 = blk: {
    var t: [256]u16 = @splat(0);
    for ("acdglpsuwxz", 0..) |cl, i| {
        t[cl] = 1 << i;
        t[std.ascii.toUpper(cl)] = 1 << i;
    }
    break :blk t;
};

/// The C locale's `<ctype.h>` classes, one bit per letter of `class_bit`.
const ctype: [256]u16 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u16 = @splat(0);
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const alpha = std.ascii.isAlphabetic(c);
        const digit = std.ascii.isDigit(c);
        const cntrl = c < 0x20 or c == 0x7f;
        const graph = c > 0x20 and c < 0x7f;
        const preds = [_]bool{
            alpha,
            cntrl,
            digit,
            graph,
            std.ascii.isLower(c),
            graph and !alpha and !digit,
            c == ' ' or (c >= '\t' and c <= '\r'),
            std.ascii.isUpper(c),
            alpha or digit,
            std.ascii.isHex(c),
            c == 0,
        };
        for (preds, 0..) |b, bit| {
            if (b) t[i] |= 1 << bit;
        }
    }
    break :blk t;
};

/// The 0-based start for an `init` argument (`posrelatI` minus one): negative
/// values count from the end, and values past the end stay past it.
pub fn startIndex(init: i64, len: usize) usize {
    if (init > 0) return @intCast(init - 1);
    if (init == 0) return 0;
    const back = @as(u64, @intCast(-(init + 1))) + 1;
    return if (back > len) 0 else len - back;
}

/// Whether the pattern has no magic bytes, so `string.find` may search for it
/// as a plain string (`nospecials`).
pub fn hasSpecials(pattern: []const u8) bool {
    return std.mem.findAny(u8, pattern, specials) != null;
}

/// `string.find` with `plain`, or with a pattern without specials: the first
/// occurrence of `needle` at or after `init`.
pub fn findPlain(src: []const u8, needle: []const u8, init: usize) ?Span {
    if (init > src.len) return null;
    const i = std.mem.findPos(u8, src, init, needle) orelse return null;
    return .{ .start = i, .end = i + needle.len };
}

/// `string.find` and `string.match`: the first match starting at or after
/// `init`, or only at `init` for an anchored pattern. The captures are then in
/// `m`. `init` comes from `startIndex`.
pub fn find(m: *Matcher, init: usize) Error!?Span {
    if (init > m.src.len) return null;
    var s = init;
    while (true) {
        if (try m.matchAt(s)) |e| return .{ .start = s, .end = e };
        s += 1;
        if (m.anchor or s > m.src.len) return null;
    }
}

/// The iterator `string.gmatch` returns. A '^' does not anchor here: it
/// matches itself, as in the reference.
pub const Gmatch = struct {
    m: Matcher,
    pos: usize,
    last: ?usize = null,

    /// `init` comes from `startIndex`.
    pub fn init(src: []const u8, pattern: []const u8, start: usize) Gmatch {
        return .{
            .m = .{ .src = src, .pattern = pattern, .anchor = false },
            .pos = @min(start, src.len + 1),
        };
    }

    /// The next match, skipping an empty match where the last one ended. The
    /// captures are then in `m`.
    pub fn next(g: *Gmatch) Error!?Span {
        var s = g.pos;
        while (s <= g.m.src.len) : (s += 1) {
            if (try g.m.matchAt(s)) |e| {
                if (e != g.last) {
                    g.pos = e;
                    g.last = e;
                    return .{ .start = s, .end = e };
                }
            }
        }
        g.pos = s;
        return null;
    }
};

/// The result of `gsub`: how many matches were replaced, and whether any
/// replacement changed the subject (when none did, `string.gsub` returns the
/// original string).
pub const GsubResult = struct {
    count: i64,
    changed: bool,
};

/// `string.gsub`'s loop: write the subject to `w` with up to `max_n` matches
/// replaced. `replacer` decides each replacement through
///
///     fn replace(self, m: *Matcher, match: Span, w: *Writer) !bool
///
/// which writes the replacement (or the original `m.src[match.start..match.end]`)
/// and returns whether it changed the subject. `StringReplacement` is the one
/// for a string or number replacement; a table or function replacement reads
/// `m.capture(0, match)` or the `m.resultCount()` captures, and when the Lua
/// value is false or nil, writes the original text and returns false.
///
/// Out of line, one instance per replacer: inlined into `string.gsub`,
/// the three instances' locals all sat in its frame, which is on the
/// native stack of every level of a `gsub` inside a replacement function.
pub noinline fn gsub(m: *Matcher, max_n: i64, w: *Writer, replacer: anytype) !GsubResult {
    var src: usize = 0;
    var last: ?usize = null;
    var n: i64 = 0;
    var changed = false;
    while (n < max_n) {
        const e = try m.matchAt(src);
        if (e != null and e != last) {
            n += 1;
            const span: Span = .{ .start = src, .end = e.? };
            if (try replacer.replace(m, span, w)) changed = true;
            src = e.?;
            last = e;
        } else if (src < m.src.len) {
            try w.writeByte(m.src[src]);
            src += 1;
        } else break;
        if (m.anchor) break;
    }
    try w.writeAll(m.src[src..]);
    return .{ .count = n, .changed = changed };
}

/// A string replacement for `gsub`: `%0` is the whole match, `%1`-`%9` the
/// captures, and `%%` a '%' (`add_s`).
pub const StringReplacement = struct {
    text: []const u8,

    pub fn replace(r: StringReplacement, m: *Matcher, match: Span, w: *Writer) (Error || Writer.Error)!bool {
        var news = r.text;
        while (std.mem.findScalar(u8, news, esc)) |i| {
            try w.writeAll(news[0..i]);
            const c: u8 = if (i + 1 < news.len) news[i + 1] else 0;
            switch (c) {
                esc => try w.writeByte(esc),
                '0' => try w.writeAll(m.src[match.start..match.end]),
                '1'...'9' => switch (try m.capture(c - '1', match)) {
                    .string => |s| try w.writeAll(s),
                    .position => |pos| try w.print("{d}", .{pos}),
                },
                else => return m.diag.fail("invalid use of '%' in replacement string", .{}),
            }
            news = news[i + 2 ..];
        }
        try w.writeAll(news);
        return true;
    }
};

// Expected values below come from reference Lua 5.5.1 (`lua` in the dev
// shell), mostly from the cases in test/lua-5.5.1-tests/pm.lua.

/// `string.find` as Lua prints its results, separated by spaces: positions
/// then captures, "nil" when nothing matches, or "error: " and the message.
fn findText(s: []const u8, p: []const u8, init: i64, plain: bool) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const start = startIndex(init, s.len);
    if (plain or !hasSpecials(p)) {
        const span = (if (start > s.len) null else findPlain(s, p, start)) orelse {
            try w.writeAll("nil");
            return out.toOwnedSlice();
        };
        try w.print("{d} {d}", .{ span.start + 1, span.end });
        return out.toOwnedSlice();
    }
    var m: Matcher = .init(s, p);
    const span = find(&m, start) catch {
        try w.print("error: {s}", .{m.diag.message()});
        return out.toOwnedSlice();
    } orelse {
        try w.writeAll("nil");
        return out.toOwnedSlice();
    };
    try w.print("{d} {d}", .{ span.start + 1, span.end });
    for (0..m.level) |i| {
        try writeCapture(w, &m, i, span);
    }
    return out.toOwnedSlice();
}

fn writeCapture(w: *Writer, m: *Matcher, i: usize, span: Span) !void {
    const c = m.capture(i, span) catch {
        try w.print(" error: {s}", .{m.diag.message()});
        return;
    };
    switch (c) {
        .string => |str| try w.print(" {s}", .{str}),
        .position => |pos| try w.print(" {d}", .{pos}),
    }
}

/// `string.match`, printed like `findText`.
fn matchText(s: []const u8, p: []const u8, init: i64) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var m: Matcher = .init(s, p);
    const span = find(&m, startIndex(init, s.len)) catch {
        try w.print("error: {s}", .{m.diag.message()});
        return out.toOwnedSlice();
    } orelse {
        try w.writeAll("nil");
        return out.toOwnedSlice();
    };
    for (0..m.resultCount()) |i| {
        try writeCapture(w, &m, i, span);
    }
    return out.toOwnedSlice();
}

fn expectFind(expected: []const u8, s: []const u8, p: []const u8) !void {
    const got = try findText(s, p, 1, false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectMatch(expected: []const u8, s: []const u8, p: []const u8) !void {
    const got = try matchText(s, p, 1);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "find returns positions, captures, and anchored failures" {
    try expectFind("1 0", "", "");
    try expectFind("1 0", "alo", "");
    try expectFind("9 11", "a\x00a\x00a\x00a\x00\x00ab", "\x00ab");
    try expectFind("nil", "a\x00a\x00a\x00a\x00\x00ab", "b\x00");
    try expectFind("nil", "", "\x00");
    try expectFind("4 5", "alo123alo", "12");
    try expectFind("nil", "alo123alo", "^12");
    try expectFind("2 2", "b$a", "$\x00?");
    try expectFind("4 4", "abc\x00efg", "%\x00");
    try expectFind("4 5", "abc\x00\x00", "\x00.");
    try expectFind("2 5", " alo aalo allo", "%f[%S].-%f[%s].-%f[%S]");
    try expectFind("1 0", "a", "%f[a]");
    try expectFind("2 1", "a", "%f[^%l]");
    try expectFind("4 3", "aba", "%f[%z]");
    try expectFind("nil", "aba", "%f[%l%z]");
    try expectFind("1 3 1 aaa 4", "aaa", "()(a*)()");
}

test "find honors init, plain, and negative starts" {
    const cases = [_]struct { s: []const u8, p: []const u8, init: i64, plain: bool, want: []const u8 }{
        .{ .s = "a\x00o a\x00o a\x00o", .p = "a\x00o", .init = 2, .plain = false, .want = "5 7" },
        .{ .s = "a\x00o a\x00o a\x00o", .p = "a\x00o", .init = 9, .plain = false, .want = "9 11" },
        .{ .s = "abc", .p = "", .init = 4, .plain = false, .want = "4 3" },
        .{ .s = "abc", .p = "", .init = 5, .plain = false, .want = "nil" },
        .{ .s = "abc", .p = "a.", .init = 5, .plain = false, .want = "nil" },
        .{ .s = "abcabc", .p = "b", .init = -3, .plain = false, .want = "5 5" },
        .{ .s = "abcabc", .p = "b", .init = -100, .plain = false, .want = "2 2" },
        .{ .s = "a.b", .p = ".", .init = 1, .plain = true, .want = "2 2" },
        .{ .s = "a+b", .p = "+", .init = 1, .plain = true, .want = "2 2" },
        .{ .s = "x^ab", .p = "^a", .init = 1, .plain = true, .want = "2 3" },
        .{ .s = "abc", .p = "^b", .init = 2, .plain = false, .want = "2 2" },
        .{ .s = "abc", .p = "b", .init = std.math.maxInt(i64), .plain = false, .want = "nil" },
        .{ .s = "abc", .p = "b", .init = std.math.minInt(i64), .plain = false, .want = "2 2" },
    };
    for (cases) |c| {
        const got = try findText(c.s, c.p, c.init, c.plain);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "quantifiers, classes, and sets" {
    try expectMatch(" aaab", "aaab", ".*b");
    try expectMatch(" aaa", "aaa", ".+a");
    try expectMatch("nil", "b", ".+b");
    try expectMatch(" ab", "aaab", ".?b");
    try expectMatch(" aaa", "aaab", "a*");
    try expectMatch(" ", "aaab", "a-");
    try expectMatch(" baaab", "aabaaabaaabaaaba", "b.-b");
    try expectMatch(" baaabaaabaaab", "aabaaabaaabaaaba", "b.*b");
    try expectMatch(" a$", "a$a", ".%$");
    try expectMatch(" a$a", "a$a", ".$.");
    try expectMatch("nil", "a$a", "$$");
    try expectMatch(" xuxu", "  \n\r*&\n\r   xuxu  \n\n", "%g%g%g+");
    try expectMatch(" ?", "um caracter ? extra", "[^%sa-z]");
    try expectMatch(" \xc3\xa1b", "]]]\xc3\xa1b", "[^]]+");
    try expectMatch(" 0a", "0alo alo", "%x*");
    try expectMatch(" \x00\x01\x02", "ab\x00\x01\x02c", "[\x00-\x02]+");
    try expectMatch(" \x00", "ab\x00\x01\x02c", "[\x00-\x00]+");
    try expectMatch(" \x00\x00", "abc\x00\x00\x00", "%\x00%\x00?");
    try expectMatch("nil", "a-z", "[a%-]+$");
    try expectMatch(" a-", "a-z", "[a-]+");
    try expectMatch(" %]", "x%]", "[]%%]+");
    try expectMatch(" ^[-]", "^[-]ab", "[%^%[%-%]]+");
    try expectMatch(" \t\x0b", "a\t\x0bb", "%s+");
    try expectMatch(" \x7f", "a\x7f", "%c");
    try expectMatch(" !/", "ab!/9", "%p+");
    try expectMatch(" \xff", "a\xff", "%A$");
}

test "captures, position captures, and back-references" {
    try expectMatch(" xyz", "alo xyzK", "(%w+)K");
    try expectMatch(" ", "254 K", "(%d*)K");
    try expectMatch(" 0123456789  11", "0123456789", "(.+(.?)())");
    try expectMatch(" b\x00o b\x00o b\x00o", "alo alx 123 b\x00o b\x00o", "((..*) %2)");
    try expectMatch(" 3= 4= 4 3 3  4", "axz123= 4= 4 34", "((.+)=(.*)=%3 %2)");
    try expectMatch(" ======= ===", "=======", "^((=*)=%2)$");
    try expectMatch("nil", "==========", "^([=]*)=%1$");
    try expectMatch(" error: unfinished capture", "a", "(.");
    try expectMatch(" \x00efg\x00\x01e\x01", "abc\x00efg\x00\x01e\x01g", "%b\x00\x01");
    try expectMatch(" (a(b)c)", "x(a(b)c)y", "%b()");
    try expectMatch("nil", "x(a(b c", "%b()");
}

test "malformed patterns report the reference's messages" {
    const cases = [_]struct { p: []const u8, msg: []const u8 }{
        .{ .p = ".)", .msg = "invalid pattern capture" },
        .{ .p = "[a", .msg = "malformed pattern (missing ']')" },
        .{ .p = "[]", .msg = "malformed pattern (missing ']')" },
        .{ .p = "[^]", .msg = "malformed pattern (missing ']')" },
        .{ .p = "[a%]", .msg = "malformed pattern (missing ']')" },
        .{ .p = "[a%", .msg = "malformed pattern (missing ']')" },
        .{ .p = "%b", .msg = "malformed pattern (missing arguments to '%b')" },
        .{ .p = "%ba", .msg = "malformed pattern (missing arguments to '%b')" },
        .{ .p = "%", .msg = "malformed pattern (ends with '%')" },
        .{ .p = "%f", .msg = "missing '[' after '%f' in pattern" },
        .{ .p = "(%0)", .msg = "invalid capture index %0" },
        .{ .p = "(%1)", .msg = "invalid capture index %1" },
        .{ .p = "(.)%2", .msg = "invalid capture index %2" },
        .{ .p = &@as([33]u8, @splat('(')), .msg = "too many captures" },
    };
    for (cases) |c| {
        var m: Matcher = .init("a", c.p);
        try testing.expectError(error.PatternError, find(&m, 0));
        try testing.expectEqualStrings(c.msg, m.diag.message());
    }
    // The recursion limit counts nested items, so it takes a long subject.
    var deep: Matcher = .init(&@as([300]u8, @splat('a')), std.mem.asBytes(&@as([300][2]u8, @splat("a?".*))));
    try testing.expectError(error.PatternError, find(&deep, 0));
    try testing.expectEqualStrings("pattern too complex", deep.diag.message());
    // 32 captures is the limit, not an error.
    var m: Matcher = .init("a", &@as([32]u8, @splat('(')) ++ &@as([32]u8, @splat(')')));
    try testing.expect((try find(&m, 0)) != null);
    try testing.expectEqual(32, m.level);
}

test "long subjects match without deep recursion" {
    const a = try testing.allocator.alloc(u8, 300000);
    defer testing.allocator.free(a);
    @memset(a, 'a');
    var m: Matcher = .init(a, "^a*.?$");
    try testing.expect((try find(&m, 0)) != null);
    m = .init(a, "^a*.?b$");
    try testing.expect((try find(&m, 0)) == null);
    m = .init(a, "^a-.?$");
    try testing.expect((try find(&m, 0)) != null);
}

/// `string.gsub` with a string replacement, printed as the new string, a tab,
/// and the count, or "error: " and the message.
fn gsubText(s: []const u8, p: []const u8, repl: []const u8, max_n: ?i64) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var m: Matcher = .init(s, p);
    const max = max_n orelse @as(i64, @intCast(s.len)) + 1;
    const r = gsub(&m, max, &out.writer, StringReplacement{ .text = repl }) catch |err| switch (err) {
        error.PatternError => {
            out.clearRetainingCapacity();
            try out.writer.print("error: {s}", .{m.diag.message()});
            return out.toOwnedSlice();
        },
        else => |e| return e,
    };
    try out.writer.print("\t{d}", .{r.count});
    return out.toOwnedSlice();
}

test "gsub with string replacements" {
    const cases = [_]struct { s: []const u8, p: []const u8, r: []const u8, n: ?i64 = null, want: []const u8 }{
        .{ .s = "xxx", .p = "x*", .r = "-", .want = "-\t1" },
        .{ .s = "a b cd", .p = " *", .r = "-", .want = "-a-b-c-d-\t5" },
        .{ .s = "alo \xc3\xbalo  ", .p = " +$", .r = "", .want = "alo \xc3\xbalo\t1" },
        .{ .s = "  alo alo  ", .p = "^%s*(.-)%s*$", .r = "%1", .want = "alo alo\t1" },
        .{ .s = "abc=xyz", .p = "(%w*)(%p)(%w+)", .r = "%3%2%1-%0", .want = "xyz=abc-abc=xyz\t1" },
        .{ .s = "abc", .p = "%w", .r = "%1%0", .want = "aabbcc\t3" },
        .{ .s = "abc", .p = "%w+", .r = "%0%1", .want = "abcabc\t1" },
        .{ .s = "alo alo", .p = "()[al]", .r = "%1", .want = "12o 56o\t4" },
        .{ .s = "abcd", .p = "(.)", .r = "%0@", .n = 2, .want = "a@b@cd\t2" },
        .{ .s = "abcd", .p = ".", .r = "x", .n = 0, .want = "abcd\t0" },
        .{ .s = "abcd", .p = ".", .r = "x", .n = -1, .want = "abcd\t0" },
        .{ .s = "", .p = "^", .r = "r", .want = "r\t1" },
        .{ .s = "", .p = "$", .r = "r", .want = "r\t1" },
        .{ .s = "abc", .p = "$", .r = "\x00z", .want = "abc\x00z\t1" },
        .{ .s = "aaa", .p = "^a", .r = "b", .want = "baa\t1" },
        .{ .s = "100%", .p = "%%", .r = "%% pct", .want = "100% pct\t1" },
        .{ .s = "hello world", .p = "o", .r = "0", .want = "hell0 w0rld\t2" },
        .{ .s = "alo 'oi' alo", .p = "%b''", .r = "\"", .want = "alo \" alo\t1" },
        .{ .s = "aaa aa a aaa a", .p = "%f[%w]a", .r = "x", .want = "xaa xa x xaa x\t5" },
        .{ .s = "01abc45de3", .p = "%f[%d]", .r = ".", .want = ".01abc.45de.3\t3" },
        .{ .s = "function", .p = "%f[^\x01-\xff]", .r = ".", .want = "function.\t1" },
        .{ .s = "alo", .p = ".", .r = "%2", .want = "error: invalid capture index %2" },
        .{ .s = "alo", .p = "(%0)", .r = "a", .want = "error: invalid capture index %0" },
        .{ .s = "alo", .p = ".", .r = "%x", .want = "error: invalid use of '%' in replacement string" },
        .{ .s = "alo", .p = ".", .r = "a%", .want = "error: invalid use of '%' in replacement string" },
        .{ .s = "alo", .p = "(.", .r = "%1", .want = "error: unfinished capture" },
    };
    for (cases) |c| {
        const got = try gsubText(c.s, c.p, c.r, c.n);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

/// A replacer like a Lua table: it maps the first capture through `map` and
/// keeps the original text for keys it lacks.
const TableReplacement = struct {
    map: []const [2][]const u8,

    pub fn replace(r: TableReplacement, m: *Matcher, match: Span, w: *Writer) !bool {
        const key = switch (try m.capture(0, match)) {
            .string => |s| s,
            .position => return error.TestUnexpectedResult,
        };
        for (r.map) |kv| {
            if (std.mem.eql(u8, kv[0], key)) {
                try w.writeAll(kv[1]);
                return true;
            }
        }
        try w.writeAll(m.src[match.start..match.end]);
        return false;
    }
};

test "gsub reports whether a callback changed the subject" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var m: Matcher = .init("alo alo", "(.).");
    var r = try gsub(&m, 8, &out.writer, TableReplacement{ .map = &.{ .{ "a", "AA" }, .{ "l", "K" } } });
    try testing.expectEqualStrings("AAo AAo", out.written());
    try testing.expectEqual(GsubResult{ .count = 3, .changed = true }, r);

    out.clearRetainingCapacity();
    m = .init("alo alo", ".");
    r = try gsub(&m, 8, &out.writer, TableReplacement{ .map = &.{} });
    try testing.expectEqualStrings("alo alo", out.written());
    try testing.expectEqual(GsubResult{ .count = 7, .changed = false }, r);
}

/// Every match of `string.gmatch`, each as its values joined by commas and
/// followed by ';'.
fn gmatchText(s: []const u8, p: []const u8, init: i64) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var g: Gmatch = .init(s, p, startIndex(init, s.len));
    while (try g.next()) |span| {
        for (0..g.m.resultCount()) |i| {
            if (i > 0) try out.writer.writeByte(',');
            switch (try g.m.capture(i, span)) {
                .string => |str| try out.writer.writeAll(str),
                .position => |pos| try out.writer.print("{d}", .{pos}),
            }
        }
        try out.writer.writeByte(';');
    }
    return out.toOwnedSlice();
}

test "gmatch iterates with init and the empty-match rule" {
    const cases = [_]struct { s: []const u8, p: []const u8, init: i64 = 1, want: []const u8 }{
        .{ .s = "abcde", .p = "()", .want = "1;2;3;4;5;6;" },
        .{ .s = "first second word", .p = "%w+", .want = "first;second;word;" },
        .{ .s = "xuxx uu ppar r", .p = "()(.)%2", .want = "3,x;6,u;9,p;" },
        .{ .s = "a  \nbc\t\td", .p = "()%s*()", .want = "1,1;2,5;6,6;7,9;10,10;" },
        .{ .s = "10 20 30", .p = "%d+", .init = 3, .want = "20;30;" },
        .{ .s = "11 21 31", .p = "%d+", .init = -4, .want = "1;31;" },
        .{ .s = "11 21 31", .p = "%w*", .init = 9, .want = ";" },
        .{ .s = "11 21 31", .p = "%w*", .init = 10, .want = "" },
        .{ .s = "a^b^^b", .p = "^b", .want = "^b;^b;" },
        .{ .s = "abc", .p = "x*", .want = ";;;;" },
        .{ .s = "alo alo th02 is 1hat", .p = "()%f[%w%d]", .want = "1;5;9;14;17;" },
    };
    for (cases) |c| {
        const got = try gmatchText(c.s, c.p, c.init);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "gmatch resets the recursion limit after an error" {
    const p = std.mem.asBytes(&@as([300][2]u8, @splat("a?".*)));
    var g: Gmatch = .init(&@as([300]u8, @splat('a')), p, 0);
    try testing.expectError(error.PatternError, g.next());
    try testing.expectEqualStrings("pattern too complex", g.m.diag.message());
    g.pos = 0;
    try testing.expectError(error.PatternError, g.next());
}

test "classes match the C locale" {
    // Expected sets from the reference: string.gsub over all 256 bytes.
    const cases = [_]struct { cl: u8, count: usize }{
        .{ .cl = 'a', .count = 52 }, .{ .cl = 'c', .count = 33 }, .{ .cl = 'd', .count = 10 },
        .{ .cl = 'g', .count = 94 }, .{ .cl = 'l', .count = 26 }, .{ .cl = 'p', .count = 32 },
        .{ .cl = 's', .count = 6 },  .{ .cl = 'u', .count = 26 }, .{ .cl = 'w', .count = 62 },
        .{ .cl = 'x', .count = 22 }, .{ .cl = 'z', .count = 1 },
    };
    for (cases) |c| {
        var n: usize = 0;
        var upper: usize = 0;
        for (0..256) |b| {
            if (matchClass(@intCast(b), c.cl)) n += 1;
            if (matchClass(@intCast(b), std.ascii.toUpper(c.cl))) upper += 1;
        }
        try testing.expectEqual(c.count, n);
        try testing.expectEqual(256 - c.count, upper);
    }
}
