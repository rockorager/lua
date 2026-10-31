//! The input/output library (manual §6.8) in C-API builds: reference Lua
//! 5.5.1's liolib.c, function by function, on C's stdio and the C API.
//!
//! A file handle is what lauxlib.h promises C modules: a full userdata
//! whose first bytes are `luaL_Stream { FILE *f; lua_CFunction closef; }`,
//! with the "FILE*" metatable. So a module can read `f` from a handle Lua
//! opened (luafilesystem's `setmode` and `lock`, luaposix's `fileno`), or
//! make a handle around its own `FILE *` and close function that `io`
//! then reads, writes, and closes (luaposix's `fdopen`). The default build
//! has no libc and keeps `lib/io.zig`, which emulates glibc's stdio in
//! Zig; this file replaces it when `lua_options.c_api` is set
//! (`lib/init.zig`). docs/slop/c-api.md has the design.
//!
//! Every function here is a C function, called through the trampoline,
//! so it may use the API functions that raise. It calls them by their C
//! names, as liolib.c does, which also keeps `luaL_fileresult` the one
//! the C API exports. `io.stdout` is the host's C stream (`Host.cstdout`),
//! which `print` writes to as well.

const std = @import("std");
const builtin = @import("builtin");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const Userdata = @import("../Userdata.zig");
const gc = @import("../gc.zig");
const vm = @import("../vm.zig");
const aux = @import("../lib/auxlib.zig");
const base = @import("../lib/base.zig");
const capi = @import("capi.zig");
const lauxlib = @import("lauxlib.zig");

const Error = Value.Error;
const CFile = std.c.FILE;
// The headers' type names, as in capi.zig.
const lua_State = capi.lua_State; // ziglint-ignore: Z006
const lua_CFunction = capi.lua_CFunction; // ziglint-ignore: Z006
const lua_Integer = capi.lua_Integer; // ziglint-ignore: Z006
const Buffer = lauxlib.Buffer;
const Reg = lauxlib.Reg;

/// lauxlib.h's `luaL_Stream`: what every file handle's userdata starts
/// with. `closef` is null once the file is closed.
pub const Stream = extern struct {
    f: ?*CFile,
    closef: ?lua_CFunction,
};

/// `LUA_FILEHANDLE`.
const handle_name = "FILE*";
const input_key = "_IO_input";
const output_key = "_IO_output";
/// `L_MAXLENNUM`: the longest numeral `read("n")` accepts.
const max_numeral = 200;
/// `MAXARGLINE`.
const max_lines_args = 250;
/// `LUAL_BUFFERSIZE`.
const buffer_size = @sizeOf(@FieldType(@FieldType(Buffer, "init"), "b"));
const tnumber = 3;

// The C API, by its C names (exported by capi.zig and lauxlib.zig).
extern fn lua_gettop(L: *lua_State) c_int;
extern fn lua_settop(L: *lua_State, idx: c_int) void;
extern fn lua_pushvalue(L: *lua_State, idx: c_int) void;
extern fn lua_rotate(L: *lua_State, idx: c_int, n: c_int) void;
extern fn lua_copy(L: *lua_State, from: c_int, to: c_int) void;
extern fn lua_type(L: *lua_State, idx: c_int) c_int;
extern fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
extern fn lua_tointegerx(L: *lua_State, idx: c_int, isnum: ?*c_int) lua_Integer;
extern fn lua_tolstring(L: *lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8;
extern fn lua_rawlen(L: *lua_State, idx: c_int) u64;
extern fn lua_touserdata(L: *lua_State, idx: c_int) ?*anyopaque;
extern fn lua_pushnil(L: *lua_State) void;
extern fn lua_pushinteger(L: *lua_State, n: lua_Integer) void;
extern fn lua_pushboolean(L: *lua_State, b: c_int) void;
extern fn lua_pushstring(L: *lua_State, s: ?[*:0]const u8) ?[*:0]const u8;
extern fn lua_pushlstring(L: *lua_State, s: ?[*]const u8, len: usize) [*:0]const u8;
extern fn lua_pushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) void;
extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) c_int;
extern fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
extern fn lua_newuserdatauv(L: *lua_State, sz: usize, nuv: c_int) ?*anyopaque;
extern fn lua_stringtonumber(L: *lua_State, s: [*:0]const u8) usize;
extern fn lua_numbertocstring(L: *lua_State, idx: c_int, buff: [*]u8) c_uint;
extern fn lua_concat(L: *lua_State, n: c_int) void;
extern fn lua_error(L: *lua_State) c_int;
extern fn luaL_checkversion_(L: *lua_State, ver: f64, sz: usize) void;
extern fn luaL_checkudata(L: *lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque;
extern fn luaL_testudata(L: *lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque;
extern fn luaL_setmetatable(L: *lua_State, tname: [*:0]const u8) void;
extern fn luaL_newmetatable(L: *lua_State, tname: [*:0]const u8) c_int;
extern fn luaL_setfuncs(L: *lua_State, l: [*]const Reg, nup: c_int) void;
extern fn luaL_checkany(L: *lua_State, arg: c_int) void;
extern fn luaL_checklstring(L: *lua_State, arg: c_int, l: ?*usize) [*:0]const u8;
extern fn luaL_optlstring(L: *lua_State, arg: c_int, def: ?[*:0]const u8, l: ?*usize) ?[*:0]const u8;
extern fn luaL_checkinteger(L: *lua_State, arg: c_int) lua_Integer;
extern fn luaL_optinteger(L: *lua_State, arg: c_int, def: lua_Integer) lua_Integer;
extern fn luaL_checkoption(L: *lua_State, arg: c_int, def: ?[*:0]const u8, lst: [*]const ?[*:0]const u8) c_int;
extern fn luaL_checkstack(L: *lua_State, sz: c_int, msg: ?[*:0]const u8) void;
extern fn luaL_argerror(L: *lua_State, arg: c_int, extramsg: [*:0]const u8) c_int;
extern fn luaL_fileresult(L: *lua_State, stat: c_int, fname: ?[*:0]const u8) c_int;
extern fn luaL_where(L: *lua_State, lvl: c_int) void;
extern fn luaL_buffinit(L: *lua_State, B: *Buffer) void;
extern fn luaL_prepbuffsize(B: *Buffer, sz: usize) [*]u8;
extern fn luaL_pushresult(B: *Buffer) void;

// C's stdio beyond what std.c declares.
extern "c" fn fflush(stream: ?*CFile) c_int;
extern "c" fn fseeko(stream: *CFile, offset: i64, whence: c_int) c_int;
extern "c" fn ftello(stream: *CFile) i64;
extern "c" fn fileno(stream: *CFile) c_int;
extern "c" fn setvbuf(stream: *CFile, buf: ?[*]u8, mode: c_int, size: usize) c_int;
extern "c" fn clearerr(stream: *CFile) void;
extern "c" fn ferror(stream: *CFile) c_int;
extern "c" fn getc(stream: *CFile) c_int;
extern "c" fn getc_unlocked(stream: *CFile) c_int;
extern "c" fn ungetc(c: c_int, stream: *CFile) c_int;
extern "c" fn flockfile(stream: *CFile) void;
extern "c" fn funlockfile(stream: *CFile) void;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern "c" fn pclose(stream: *CFile) c_int;
extern "c" fn tmpfile() ?*CFile;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn __uflow(stream: *CFile) c_int;

const darwin = builtin.os.tag.isDarwin();
const c_stdin = @extern(**CFile, .{ .name = if (darwin) "__stdinp" else "stdin" });
const c_stderr = @extern(**CFile, .{ .name = if (darwin) "__stderrp" else "stderr" });

const eof: c_int = -1;

inline fn errno() *c_int {
    return @ptrCast(std.c._errno());
}

inline fn upvalueIndex(i: c_int) c_int {
    return capi.registry_index - i;
}

/// `l_getc`: glibc's `getc_unlocked` macro, which reads the stream's
/// buffer in place; elsewhere the function.
inline fn getcUnlocked(f: *CFile) c_int {
    if (comptime builtin.target.isGnuLibC()) {
        // glibc's `struct _IO_FILE` starts with these, as its macro reads.
        const G = extern struct { flags: c_int, read_ptr: [*]u8, read_end: [*]u8 };
        const g: *G = @ptrCast(@alignCast(f));
        if (@intFromPtr(g.read_ptr) < @intFromPtr(g.read_end)) {
            const c = g.read_ptr[0];
            g.read_ptr += 1;
            return c;
        }
        return __uflow(f);
    }
    return getc_unlocked(f);
}

/// `luaL_error`: raises the pieces, concatenated, after the position of
/// the calling Lua code.
fn raise(L: *lua_State, parts: []const []const u8) noreturn {
    luaL_where(L, 1);
    for (parts) |p| _ = lua_pushlstring(L, p.ptr, p.len);
    lua_concat(L, @intCast(parts.len + 1));
    _ = lua_error(L);
    unreachable;
}

/// lauxlib.c's `luaL_execresult`, for `pclose`'s status; `lauxlib.zig`
/// exports it under that name.
pub fn execResult(L: *lua_State, stat_in: c_int) callconv(.c) c_int {
    if (stat_in != 0 and errno().* != 0) return luaL_fileresult(L, 0, null);
    var stat = stat_in;
    var what: [*:0]const u8 = "exit";
    // `l_inspectstat`: WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG.
    const s: u32 = @bitCast(stat);
    const sig = s & 0x7f;
    if (sig == 0) {
        stat = @intCast((s >> 8) & 0xff);
    } else if (sig != 0x7f) {
        stat = @intCast(sig);
        what = "signal";
    }
    if (what[0] == 'e' and stat == 0) lua_pushboolean(L, 1) else lua_pushnil(L);
    _ = lua_pushstring(L, what);
    lua_pushinteger(L, stat);
    return 3;
}

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

/// `tolstream`.
fn toStream(L: *lua_State) *Stream {
    return @ptrCast(@alignCast(luaL_checkudata(L, 1, handle_name)));
}

inline fn isClosed(p: *const Stream) bool {
    return p.closef == null;
}

/// `l_checkmode`: "[rwa]%+?b*".
fn checkMode(mode: []const u8) bool {
    if (mode.len == 0 or std.mem.findScalar(u8, "rwa", mode[0]) == null) return false;
    var i: usize = 1;
    if (i < mode.len and mode[i] == '+') i += 1;
    for (mode[i..]) |c| if (c != 'b') return false;
    return true;
}

fn ioType(L: *lua_State) callconv(.c) c_int {
    luaL_checkany(L, 1);
    const p: ?*Stream = @ptrCast(@alignCast(luaL_testudata(L, 1, handle_name)));
    if (p) |s| {
        _ = lua_pushstring(L, if (isClosed(s)) "closed file" else "file");
    } else lua_pushnil(L);
    return 1;
}

fn fTostring(L: *lua_State) callconv(.c) c_int {
    const p = toStream(L);
    if (isClosed(p)) {
        _ = lua_pushstring(L, "file (closed)");
    } else {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "file (0x{x})", .{@intFromPtr(p.f)}) catch unreachable;
        _ = lua_pushlstring(L, s.ptr, s.len);
    }
    return 1;
}

/// `tofile`.
fn toFile(L: *lua_State) *CFile {
    const p = toStream(L);
    if (isClosed(p)) raise(L, &.{"attempt to use a closed file"});
    return p.f.?;
}

/// `newprefile`: a closed handle, so a memory error leaves it consistent.
fn newPrefile(L: *lua_State) *Stream {
    const p: *Stream = @ptrCast(@alignCast(lua_newuserdatauv(L, @sizeOf(Stream), 0)));
    p.closef = null;
    luaL_setmetatable(L, handle_name);
    return p;
}

/// `aux_close`: marks the handle closed and calls its close function.
fn auxClose(L: *lua_State) c_int {
    const p = toStream(L);
    const cf = p.closef.?;
    p.closef = null;
    return cf(L);
}

fn fClose(L: *lua_State) callconv(.c) c_int {
    _ = toFile(L);
    return auxClose(L);
}

fn ioClose(L: *lua_State) callconv(.c) c_int {
    if (lua_type(L, 1) == capi.lua_tnone) _ = lua_getfield(L, capi.registry_index, output_key);
    return fClose(L);
}

fn fGc(L: *lua_State) callconv(.c) c_int {
    const p = toStream(L);
    if (!isClosed(p) and p.f != null) _ = auxClose(L);
    return 0;
}

/// `io_fclose`: the close function of files `io` opens.
fn ioFclose(L: *lua_State) callconv(.c) c_int {
    const p = toStream(L);
    errno().* = 0;
    return luaL_fileresult(L, @intFromBool(std.c.fclose(p.f.?) == 0), null);
}

fn newFile(L: *lua_State) *Stream {
    const p = newPrefile(L);
    p.f = null;
    p.closef = &ioFclose;
    return p;
}

fn openCheck(L: *lua_State, fname: [*:0]const u8, mode: [*:0]const u8) void {
    const p = newFile(L);
    p.f = std.c.fopen(fname, mode);
    if (p.f == null) {
        const msg = std.mem.span(strerror(errno().*));
        raise(L, &.{ "cannot open file '", std.mem.span(fname), "' (", msg, ")" });
    }
}

fn ioOpen(L: *lua_State) callconv(.c) c_int {
    const filename = luaL_checklstring(L, 1, null);
    const mode = luaL_optlstring(L, 2, "r", null).?;
    const p = newFile(L);
    if (!checkMode(std.mem.span(mode))) _ = luaL_argerror(L, 2, "invalid mode");
    errno().* = 0;
    p.f = std.c.fopen(filename, mode);
    return if (p.f == null) luaL_fileresult(L, 0, filename) else 1;
}

/// `io_pclose`: the close function of `popen` files.
fn ioPclose(L: *lua_State) callconv(.c) c_int {
    const p = toStream(L);
    errno().* = 0;
    return execResult(L, pclose(p.f.?));
}

fn ioPopen(L: *lua_State) callconv(.c) c_int {
    const filename = luaL_checklstring(L, 1, null);
    const mode = luaL_optlstring(L, 2, "r", null).?;
    const p = newPrefile(L);
    const m = std.mem.span(mode);
    if (!(m.len == 1 and (m[0] == 'r' or m[0] == 'w'))) _ = luaL_argerror(L, 2, "invalid mode");
    errno().* = 0;
    _ = fflush(null);
    p.f = popen(filename, mode);
    p.closef = &ioPclose;
    return if (p.f == null) luaL_fileresult(L, 0, filename) else 1;
}

fn ioTmpfile(L: *lua_State) callconv(.c) c_int {
    const p = newFile(L);
    errno().* = 0;
    p.f = tmpfile();
    return if (p.f == null) luaL_fileresult(L, 0, null) else 1;
}

/// `getiofile`: the default input or output.
fn getIoFile(L: *lua_State, comptime key: [:0]const u8) *CFile {
    _ = lua_getfield(L, capi.registry_index, key);
    const p: *Stream = @ptrCast(@alignCast(lua_touserdata(L, -1)));
    if (isClosed(p)) raise(L, &.{ "default ", key["_IO_".len..], " file is closed" });
    return p.f.?;
}

fn gIoFile(L: *lua_State, comptime key: [:0]const u8, mode: [*:0]const u8) c_int {
    if (lua_type(L, 1) > 0) {
        if (lua_tolstring(L, 1, null)) |filename| {
            openCheck(L, filename, mode);
        } else {
            _ = toFile(L);
            lua_pushvalue(L, 1);
        }
        lua_setfield(L, capi.registry_index, key);
    }
    _ = lua_getfield(L, capi.registry_index, key);
    return 1;
}

fn ioInput(L: *lua_State) callconv(.c) c_int {
    return gIoFile(L, input_key, "r");
}

fn ioOutput(L: *lua_State) callconv(.c) c_int {
    return gIoFile(L, output_key, "w");
}

/// `aux_lines`: the iterator over the file at 1 with the formats after it,
/// a closure over `ioReadline` with upvalues the file, the number of
/// formats, whether to close the file at the end, and the formats.
fn auxLines(L: *lua_State, toclose: bool) void {
    const n = lua_gettop(L) - 1;
    if (n > max_lines_args) _ = luaL_argerror(L, max_lines_args + 2, "too many arguments");
    lua_pushvalue(L, 1);
    lua_pushinteger(L, n);
    lua_pushboolean(L, @intFromBool(toclose));
    lua_rotate(L, 2, 3);
    lua_pushcclosure(L, &ioReadline, 3 + n);
}

fn fLines(L: *lua_State) callconv(.c) c_int {
    _ = toFile(L);
    auxLines(L, false);
    return 1;
}

fn ioLines(L: *lua_State) callconv(.c) c_int {
    if (lua_type(L, 1) == capi.lua_tnone) lua_pushnil(L);
    var toclose = false;
    if (lua_type(L, 1) == 0) {
        _ = lua_getfield(L, capi.registry_index, input_key);
        lua_copy(L, -1, 1);
        lua_settop(L, -2);
        _ = toFile(L);
    } else {
        const filename = luaL_checklstring(L, 1, null);
        openCheck(L, filename, "r");
        lua_copy(L, -1, 1);
        lua_settop(L, -2);
        toclose = true;
    }
    auxLines(L, toclose);
    if (toclose) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushvalue(L, 1);
        return 4;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// `RN`: the numeral `read_number` is reading.
const Rn = struct {
    f: *CFile,
    c: c_int = 0,
    n: usize = 0,
    buff: [max_numeral + 1]u8 = undefined,

    /// `nextc`: keeps the current byte and reads the next.
    fn nextc(rn: *Rn) bool {
        if (rn.n >= max_numeral) {
            rn.buff[0] = 0;
            return false;
        }
        rn.buff[rn.n] = @intCast(rn.c);
        rn.n += 1;
        rn.c = getcUnlocked(rn.f);
        return true;
    }

    fn test2(rn: *Rn, set: *const [2]u8) bool {
        if (rn.c == set[0] or rn.c == set[1]) return rn.nextc();
        return false;
    }

    fn readDigits(rn: *Rn, hex: bool) c_int {
        var count: c_int = 0;
        while (rn.c >= 0 and rn.c <= 255) {
            const ch: u8 = @intCast(rn.c);
            if (!(if (hex) std.ascii.isHex(ch) else std.ascii.isDigit(ch))) break;
            if (!rn.nextc()) break;
            count += 1;
        }
        return count;
    }
};

fn isSpace(c: c_int) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// `read_number`: the longest prefix of a numeral, at most `L_MAXLENNUM`
/// bytes, converted by `lua_stringtonumber`; the next byte stays unread.
fn readNumber(L: *lua_State, f: *CFile) bool {
    var rn: Rn = .{ .f = f };
    var count: c_int = 0;
    var hex = false;
    flockfile(f);
    rn.c = getcUnlocked(f);
    while (isSpace(rn.c)) rn.c = getcUnlocked(f);
    _ = rn.test2("-+");
    if (rn.test2("00")) {
        if (rn.test2("xX")) hex = true else count = 1;
    }
    count += rn.readDigits(hex);
    // The C locale's decimal point, and always a dot.
    if (rn.test2("..")) count += rn.readDigits(hex);
    if (count > 0 and rn.test2(if (hex) "pP" else "eE")) {
        _ = rn.test2("-+");
        _ = rn.readDigits(false);
    }
    _ = ungetc(rn.c, f);
    funlockfile(f);
    rn.buff[rn.n] = 0;
    if (lua_stringtonumber(L, rn.buff[0..rn.n :0]) != 0) return true;
    lua_pushnil(L);
    return false;
}

fn testEof(L: *lua_State, f: *CFile) bool {
    const c = getc(f);
    _ = ungetc(c, f);
    _ = lua_pushstring(L, "");
    return c != eof;
}

fn readLine(L: *lua_State, f: *CFile, chop: bool) bool {
    var b: Buffer = undefined;
    var c: c_int = eof;
    luaL_buffinit(L, &b);
    while (true) {
        const buff = luaL_prepbuffsize(&b, buffer_size);
        var i: usize = 0;
        flockfile(f);
        while (i < buffer_size) {
            c = getcUnlocked(f);
            if (c == eof or c == '\n') break;
            buff[i] = @intCast(c);
            i += 1;
        }
        funlockfile(f);
        b.n += i;
        if (c == eof or c == '\n') break;
    }
    if (!chop and c == '\n') {
        if (b.n >= b.size) _ = luaL_prepbuffsize(&b, 1);
        b.b[b.n] = '\n';
        b.n += 1;
    }
    luaL_pushresult(&b);
    return c == '\n' or lua_rawlen(L, -1) > 0;
}

fn readAll(L: *lua_State, f: *CFile) void {
    var b: Buffer = undefined;
    luaL_buffinit(L, &b);
    // Unlike the reference, size the buffer to what is left of a regular
    // file: our box grows by copying into a new userdata, where the
    // reference's reallocates in place.
    if (remaining(f)) |n| _ = luaL_prepbuffsize(&b, n +| buffer_size);
    while (true) {
        const p = luaL_prepbuffsize(&b, buffer_size);
        const nr = std.c.fread(p, 1, buffer_size, f);
        b.n += nr;
        if (nr != buffer_size) break;
    }
    luaL_pushresult(&b);
}

/// The bytes between `f`'s position and the end, when it is a regular file.
fn remaining(f: *CFile) ?usize {
    const pos = ftello(f);
    if (pos < 0) return null;
    const fd = fileno(f);
    var size: u64 = undefined;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(fd, "", 0x1000, .{ .TYPE = true, .SIZE = true }, &sx); // AT_EMPTY_PATH
        if (linux.errno(rc) != .SUCCESS or !linux.S.ISREG(sx.mode)) return null;
        size = sx.size;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0 or !std.c.S.ISREG(st.mode)) return null;
        size = @intCast(st.size);
    }
    return if (size > pos) @intCast(size - @as(u64, @intCast(pos))) else null;
}

fn readChars(L: *lua_State, f: *CFile, n: usize) bool {
    var b: Buffer = undefined;
    luaL_buffinit(L, &b);
    const p = luaL_prepbuffsize(&b, n);
    const nr = std.c.fread(p, 1, n, f);
    b.n += nr;
    luaL_pushresult(&b);
    return nr > 0;
}

fn gRead(L: *lua_State, f: *CFile, first: c_int) c_int {
    var nargs = lua_gettop(L) - 1;
    var n: c_int = first;
    var success: bool = true;
    clearerr(f);
    errno().* = 0;
    if (nargs == 0) {
        success = readLine(L, f, true);
        n = first + 1;
    } else {
        luaL_checkstack(L, nargs + 20, "too many arguments");
        while (nargs > 0 and success) : (n += 1) {
            nargs -= 1;
            if (lua_type(L, n) == tnumber) {
                const l: usize = @bitCast(luaL_checkinteger(L, n));
                success = if (l == 0) testEof(L, f) else readChars(L, f, l);
            } else {
                var p = luaL_checklstring(L, n, null);
                if (p[0] == '*') p += 1;
                switch (p[0]) {
                    'n' => success = readNumber(L, f),
                    'l' => success = readLine(L, f, true),
                    'L' => success = readLine(L, f, false),
                    'a' => {
                        readAll(L, f);
                        success = true;
                    },
                    else => return luaL_argerror(L, n, "invalid format"),
                }
            }
        }
    }
    if (ferror(f) != 0) return luaL_fileresult(L, 0, null);
    if (!success) {
        lua_settop(L, -2);
        lua_pushnil(L);
    }
    return n - first;
}

fn ioRead(L: *lua_State) callconv(.c) c_int {
    return gRead(L, getIoFile(L, input_key), 1);
}

fn fRead(L: *lua_State) callconv(.c) c_int {
    return gRead(L, toFile(L), 2);
}

/// The iterator `lines` returns.
fn ioReadline(L: *lua_State) callconv(.c) c_int {
    const p: *Stream = @ptrCast(@alignCast(lua_touserdata(L, upvalueIndex(1))));
    var n: c_int = @intCast(lua_tointegerx(L, upvalueIndex(2), null));
    if (isClosed(p)) raise(L, &.{"file is already closed"});
    lua_settop(L, 1);
    luaL_checkstack(L, n, "too many arguments");
    var i: c_int = 1;
    while (i <= n) : (i += 1) lua_pushvalue(L, upvalueIndex(3 + i));
    n = gRead(L, p.f.?, 2);
    if (lua_toboolean(L, -n) != 0) return n;
    if (n > 1) {
        const msg = lua_tolstring(L, -n + 1, null);
        raise(L, &.{if (msg) |m| std.mem.span(m) else "(null)"});
    }
    if (lua_toboolean(L, upvalueIndex(3)) != 0) {
        lua_settop(L, 0);
        lua_pushvalue(L, upvalueIndex(1));
        _ = auxClose(L);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Writing and the rest
// ---------------------------------------------------------------------------

fn gWrite(L: *lua_State, f: *CFile, first: c_int) c_int {
    var arg = first;
    var nargs = lua_gettop(L) - arg;
    var total: usize = 0;
    errno().* = 0;
    while (nargs > 0) : (arg += 1) {
        nargs -= 1;
        var buff: [64]u8 = undefined;
        var len: usize = lua_numbertocstring(L, arg, &buff);
        const s: [*]const u8 = if (len > 0) blk: {
            len -= 1;
            break :blk &buff;
        } else luaL_checklstring(L, arg, &len);
        const written = std.c.fwrite(s, 1, len, f);
        total += written;
        if (written < len) {
            const n = luaL_fileresult(L, 0, null);
            lua_pushinteger(L, @intCast(total));
            return n + 1;
        }
    }
    return 1;
}

fn ioWrite(L: *lua_State) callconv(.c) c_int {
    return gWrite(L, getIoFile(L, output_key), 1);
}

fn fWrite(L: *lua_State) callconv(.c) c_int {
    const f = toFile(L);
    lua_pushvalue(L, 1);
    return gWrite(L, f, 2);
}

fn fSeek(L: *lua_State) callconv(.c) c_int {
    const modes = [_]c_int{ 0, 1, 2 };
    const names = [_]?[*:0]const u8{ "set", "cur", "end", null };
    const f = toFile(L);
    const op = luaL_checkoption(L, 2, "cur", &names);
    const offset = luaL_optinteger(L, 3, 0);
    errno().* = 0;
    if (fseeko(f, offset, modes[@intCast(op)]) != 0) return luaL_fileresult(L, 0, null);
    lua_pushinteger(L, ftello(f));
    return 1;
}

fn fSetvbuf(L: *lua_State) callconv(.c) c_int {
    // _IONBF, _IOFBF, _IOLBF.
    const modes = [_]c_int{ 2, 0, 1 };
    const names = [_]?[*:0]const u8{ "no", "full", "line", null };
    const f = toFile(L);
    const op = luaL_checkoption(L, 2, null, &names);
    const sz = luaL_optinteger(L, 3, buffer_size);
    errno().* = 0;
    const res = setvbuf(f, null, modes[@intCast(op)], @bitCast(sz));
    return luaL_fileresult(L, @intFromBool(res == 0), null);
}

fn auxFlush(L: *lua_State, f: *CFile) c_int {
    errno().* = 0;
    return luaL_fileresult(L, @intFromBool(fflush(f) == 0), null);
}

fn fFlush(L: *lua_State) callconv(.c) c_int {
    return auxFlush(L, toFile(L));
}

fn ioFlush(L: *lua_State) callconv(.c) c_int {
    return auxFlush(L, getIoFile(L, output_key));
}

/// `io_noclose`: the close function of the standard files, which stay
/// open.
fn ioNoclose(L: *lua_State) callconv(.c) c_int {
    const p = toStream(L);
    p.closef = &ioNoclose;
    lua_pushnil(L);
    _ = lua_pushstring(L, "cannot close standard file");
    return 2;
}

fn reg(comptime list: anytype) [list.len + 1]Reg {
    var r: [list.len + 1]Reg = undefined;
    for (list, 0..) |e, i| r[i] = .{ .name = e[0], .func = e[1] };
    r[list.len] = .{ .name = null, .func = null };
    return r;
}

const iolib = reg(.{
    .{ "close", &ioClose },
    .{ "flush", &ioFlush },
    .{ "input", &ioInput },
    .{ "lines", &ioLines },
    .{ "open", &ioOpen },
    .{ "output", &ioOutput },
    .{ "popen", &ioPopen },
    .{ "read", &ioRead },
    .{ "tmpfile", &ioTmpfile },
    .{ "type", &ioType },
    .{ "write", &ioWrite },
});

const methods = reg(.{
    .{ "read", &fRead },
    .{ "write", &fWrite },
    .{ "lines", &fLines },
    .{ "flush", &fFlush },
    .{ "seek", &fSeek },
    .{ "close", &fClose },
    .{ "setvbuf", &fSetvbuf },
});

const metamethods = [_]Reg{
    .{ .name = "__index", .func = null },
    .{ .name = "__gc", .func = &fGc },
    .{ .name = "__close", .func = &fGc },
    .{ .name = "__tostring", .func = &fTostring },
    .{ .name = null, .func = null },
};

fn createMeta(L: *lua_State) void {
    _ = luaL_newmetatable(L, handle_name);
    luaL_setfuncs(L, &metamethods, 0);
    lua_createtable(L, 0, methods.len - 1);
    luaL_setfuncs(L, &methods, 0);
    lua_setfield(L, -2, "__index");
    lua_settop(L, -2);
}

fn createStdFile(L: *lua_State, f: *CFile, k: ?[*:0]const u8, fname: [*:0]const u8) void {
    const p = newPrefile(L);
    p.f = f;
    p.closef = &ioNoclose;
    if (k) |key| {
        lua_pushvalue(L, -1);
        lua_setfield(L, capi.registry_index, key);
    }
    lua_setfield(L, -2, fname);
}

/// `luaopen_io`. Standard output is the host's C stream, `print`'s.
fn luaopenIo(L: *lua_State) callconv(.c) c_int {
    luaL_checkversion_(L, 505, @sizeOf(lua_Integer) * 16 + @sizeOf(f64));
    lua_createtable(L, 0, iolib.len - 1);
    luaL_setfuncs(L, &iolib, 0);
    createMeta(L);
    createStdFile(L, c_stdin.*, input_key, "stdin");
    createStdFile(L, base.getHost(L).cstdout, output_key, "stdout");
    createStdFile(L, c_stderr.*, null, "stderr");
    return 1;
}

/// Opens the library into the global `io`: `luaopen_io`, called as a C
/// function.
pub fn open(th: *Thread) Error!void {
    const state = th.state;
    try th.ensureStack(1);
    const func = th.top;
    th.push(try capi.lightCFunction(th, &luaopenIo));
    try vm.call(th, func, 1);
    try aux.setField(state, state.globals, "io", th.stack[func]);
    th.top = func;
}

/// Flushes every open file handle, as `lib/io.zig`'s `flushAll` does for
/// its own: `lua_close` leaves the standard files open, and a host that
/// keeps running expects what scripts wrote to be out.
pub fn flushAll(th: *Thread) void {
    const state = th.state;
    const key = state.newString(handle_name) catch return;
    const mt = state.registry.getStr(key);
    if (mt.tag != .table) return;
    var it = gc.objects(&state.heap);
    while (it.next()) |h| {
        if (h.tag != .userdata) continue;
        const u: *Userdata = @fieldParentPtr("header", h);
        if (u.metatable != mt.asTable() or u.len < @sizeOf(Stream)) continue;
        const p: *Stream = @ptrCast(@alignCast(u.bytes().ptr));
        if (p.closef != null) {
            if (p.f) |f| _ = fflush(f);
        }
    }
}
