//! The input/output library (manual §6.8), after reference Lua 5.5.1's
//! liolib.c on glibc. Files are full userdata with the reference's metatable
//! (`__name` "FILE*", `__index` the methods, `__gc`, `__close`,
//! `__tostring`), and the library keeps the default input and output in the
//! registry under "_IO_input" and "_IO_output", as liolib.c does.
//!
//! The stream under each handle is written here, in the userdata, in place of
//! C's `FILE`: one buffer used for reading or writing, with glibc's rules for
//! buffering modes, switching between reading and writing, a failed flush
//! discarding its data, and one byte of lookahead for the number reader. All
//! I/O goes through the host's `std.Io`; `io.stdout` writes through
//! `Host.stdout`, which `print` shares. Errors carry C's errno and
//! `strerror` text, so messages and codes match the reference on Linux.

const std = @import("std");
const Value = @import("../Value.zig");
const Table = @import("../Table.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");
const Userdata = @import("../Userdata.zig");
const gc = @import("../gc.zig");
const Proto = @import("../Proto.zig");
const number = @import("../number.zig");
const aux = @import("auxlib.zig");
const base = @import("base.zig");
const os = @import("os.zig");
const package = @import("package.zig");

const Error = Value.Error;
const Args = aux.Args;
const Io = std.Io;
const File = std.Io.File;

/// `LUA_FILEHANDLE`: the metatable's registry key and `__name`.
pub const handle_name = "FILE*";
const input_key = "_IO_input";
const output_key = "_IO_output";

/// glibc's buffer for a regular file, `st_blksize` on most file systems.
const buf_size = 4096;
/// `L_MAXLENNUM`: the longest numeral `read("n")` accepts.
const max_numeral = 200;
/// `MAXARGLINE`: the most formats `lines` takes.
const max_lines_args = 250;

// ---------------------------------------------------------------------------
// errno
// ---------------------------------------------------------------------------

/// The Linux errno for an error from `std.Io`.
pub fn errnoOf(e: anyerror) i32 {
    return switch (e) {
        error.PermissionDenied => 1,
        error.FileNotFound => 2,
        error.InputOutput => 5,
        error.NoDevice => 6,
        error.NotOpenForReading, error.NotOpenForWriting => 9,
        error.WouldBlock, error.LockViolation => 11,
        error.SystemResources, error.OutOfMemory => 12,
        error.AccessDenied => 13,
        error.DeviceBusy => 16,
        error.PathAlreadyExists => 17,
        error.RenameAcrossMountPoints, error.CrossDevice => 18,
        error.NotDir => 20,
        error.IsDir => 21,
        error.InvalidArgument, error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => 22,
        error.SystemFdQuotaExceeded => 23,
        error.ProcessFdQuotaExceeded => 24,
        error.FileBusy => 26,
        error.FileTooBig => 27,
        error.NoSpaceLeft => 28,
        error.Unseekable => 29,
        error.ReadOnlyFileSystem => 30,
        error.BrokenPipe => 32,
        error.NameTooLong => 36,
        error.DirNotEmpty => 39,
        error.SymLinkLoop => 40,
        error.ConnectionResetByPeer => 104,
        error.SocketUnconnected => 107,
        error.DiskQuota => 122,
        else => 5,
    };
}

/// glibc's `strerror` for the errnos `errnoOf` gives.
pub fn strerror(code: i32) []const u8 {
    return switch (code) {
        0 => "Success",
        1 => "Operation not permitted",
        2 => "No such file or directory",
        5 => "Input/output error",
        6 => "No such device or address",
        9 => "Bad file descriptor",
        11 => "Resource temporarily unavailable",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        16 => "Device or resource busy",
        17 => "File exists",
        18 => "Invalid cross-device link",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        23 => "Too many open files in system",
        24 => "Too many open files",
        26 => "Text file busy",
        27 => "File too large",
        28 => "No space left on device",
        29 => "Illegal seek",
        30 => "Read-only file system",
        32 => "Broken pipe",
        36 => "File name too long",
        39 => "Directory not empty",
        40 => "Too many levels of symbolic links",
        104 => "Connection reset by peer",
        107 => "Transport endpoint is not connected",
        122 => "Disk quota exceeded",
        else => "Unknown error",
    };
}

/// `luaL_fileresult` for a failure with errno `code`: fail, the message
/// (prefixed with `fname` when given), and the code.
pub fn fileResultErrno(th: *Thread, code: i32, fname: ?[]const u8) Error!u32 {
    const msg = if (code != 0) strerror(code) else "(no extra info)";
    th.push(.nil);
    if (fname) |f| {
        var b: aux.Buffer = .init(th.state);
        defer b.deinit();
        b.writer.print("{s}: {s}", .{ f, msg }) catch return error.OutOfMemory;
        th.push(.string(try b.toString(th.state)));
    } else {
        th.push(.string(try th.state.newString(msg)));
    }
    th.push(.int(code));
    return 3;
}

/// `luaL_fileresult` for a failed `std.Io` call.
pub fn fileResult(th: *Thread, e: anyerror, fname: ?[]const u8) Error!u32 {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return fileResultErrno(th, errnoOf(e), fname);
}

/// `luaL_execresult` for a child's termination: true or fail, "exit" or
/// "signal", and the status or signal number.
pub fn execResult(th: *Thread, term: std.process.Child.Term) Error!u32 {
    var what: []const u8 = "exit";
    const code: i64 = switch (term) {
        .exited => |c| c,
        .signal => |s| blk: {
            what = "signal";
            break :blk @backingInt(s);
        },
        .stopped => |s| @backingInt(s),
        .unknown => |u| u,
    };
    th.push(if (std.mem.eql(u8, what, "exit") and code == 0) .true else .nil);
    th.push(.string(try th.state.newString(what)));
    th.push(.int(code));
    return 3;
}

fn cstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

// ---------------------------------------------------------------------------
// The stream
// ---------------------------------------------------------------------------

const Kind = enum(u8) {
    /// Closed, or never opened.
    closed,
    file,
    popen,
    /// A standard stream: closing it fails and leaves it open.
    std,
};

/// What sits in a file handle's userdata: C's `luaL_Stream` and `FILE`.
const Stream = struct {
    kind: Kind = .closed,
    file: File = undefined,
    child: std.process.Child = undefined,
    can_read: bool = false,
    can_write: bool = false,
    /// Every write goes to the end, as with O_APPEND.
    append: bool = false,
    /// `io.stdout`: writes go through `Host.stdout`, shared with `print`.
    host_stdout: bool = false,
    /// Reading refills from a terminal, so line-buffered output is flushed
    /// first, as glibc does.
    interactive: bool = false,
    /// glibc ignores `setvbuf`'s size without a buffer, as Lua calls it.
    vbuf: enum { no, full, line } = .full,
    mode: enum { idle, reading, writing } = .idle,
    /// The unread bytes while reading.
    rpos: usize = 0,
    rend: usize = 0,
    /// The unwritten bytes while writing.
    wlen: usize = 0,
    /// The file offset the kernel holds, as far as the stream knows.
    pos: u64 = 0,
    /// C's end-of-file and error indicators; `err` is the errno.
    eof: bool = false,
    err: i32 = 0,
    buf: [buf_size]u8 = undefined,

    fn host(th: *Thread) *base.Host {
        return base.getHost(th);
    }

    /// Fills the read buffer; 0 at the end of the file or on an error.
    fn fill(s: *Stream, th: *Thread) usize {
        if (s.eof or s.err != 0) return 0;
        const h = host(th);
        if (s.interactive) h.flushStdout();
        const n = s.file.readStreaming(h.io, &.{&s.buf}) catch |e| {
            if (e == error.EndOfStream) s.eof = true else s.err = errnoOf(e);
            return 0;
        };
        if (n == 0) s.eof = true;
        s.rpos = 0;
        s.rend = n;
        s.pos += n;
        return n;
    }

    /// Gets the stream ready to read; false with `err` set when it cannot.
    fn startRead(s: *Stream, th: *Thread) bool {
        if (!s.can_read) {
            s.err = 9;
            return false;
        }
        if (s.mode == .writing and !s.flush(th)) return false;
        s.mode = .reading;
        return true;
    }

    fn peek(s: *Stream, th: *Thread) ?u8 {
        if (s.rpos == s.rend and s.fill(th) == 0) return null;
        return s.buf[s.rpos];
    }

    /// Gets the stream ready to write: unread input is given back by moving
    /// the file offset to the logical position.
    fn startWrite(s: *Stream, th: *Thread) bool {
        if (!s.can_write) {
            s.err = 9;
            return false;
        }
        if (s.mode == .reading) {
            const unread = s.rend - s.rpos;
            if (unread > 0) {
                const io = host(th).io;
                s.pos -= unread;
                io.vtable.fileSeekTo(io.userdata, s.file, s.pos) catch |e| {
                    s.err = errnoOf(e);
                    return false;
                };
            }
            s.rpos = 0;
            s.rend = 0;
        }
        s.mode = .writing;
        return true;
    }

    /// Writes `data` to the file now.
    fn writeOut(s: *Stream, th: *Thread, data: []const u8) !void {
        const io = host(th).io;
        if (s.append) {
            const len = try s.file.length(io);
            try io.vtable.fileSeekTo(io.userdata, s.file, len);
            s.pos = len;
        }
        var i: usize = 0;
        while (i < data.len) {
            const n = s.file.writeStreaming(io, &.{}, &.{data[i..]}, 1) catch |e| {
                s.pos += i;
                return e;
            };
            i += n;
        }
        s.pos += data.len;
    }

    /// `fflush`. A failed flush drops the buffered data, as glibc does.
    fn flush(s: *Stream, th: *Thread) bool {
        if (s.host_stdout) {
            const h = host(th);
            h.stdout.flush() catch {
                s.err = errnoOf(h.file_stdout.err orelse error.InputOutput);
                return false;
            };
            return true;
        }
        if (s.mode != .writing or s.wlen == 0) return true;
        const n = s.wlen;
        s.wlen = 0;
        s.writeOut(th, s.buf[0..n]) catch |e| {
            s.err = errnoOf(e);
            return false;
        };
        return true;
    }

    /// `fwrite`, buffered as `vbuf` says, as glibc's `_IO_new_file_xsputn`
    /// does: a line-buffered write flushes through its last newline and
    /// keeps the rest. Writing nothing always succeeds.
    fn write(s: *Stream, th: *Thread, data: []const u8) bool {
        if (data.len == 0) return true;
        const nl = if (s.vbuf == .line) std.mem.findScalarLast(u8, data, '\n') else null;
        if (s.host_stdout) {
            const h = host(th);
            const w = h.stdout;
            // Up to the flush point, then the rest stays buffered.
            const cut = if (s.vbuf == .no) data.len else if (nl) |k| k + 1 else 0;
            w.writeAll(data[0..cut]) catch return s.stdoutFailed(h);
            if (cut > 0 and !s.flush(th)) return false;
            w.writeAll(data[cut..]) catch return s.stdoutFailed(h);
            return true;
        }
        if (!s.startWrite(th)) return false;
        if (s.vbuf == .no) {
            if (!s.flush(th)) return false;
            return s.writeNow(th, data);
        }
        if (nl) |k| {
            if (!s.put(th, data[0 .. k + 1]) or !s.flush(th)) return false;
            return s.put(th, data[k + 1 ..]);
        }
        return s.put(th, data);
    }

    /// Fills the buffer, flushes it when full, writes whole blocks
    /// directly, and buffers the rest.
    fn put(s: *Stream, th: *Thread, data: []const u8) bool {
        const n = @min(buf_size - s.wlen, data.len);
        @memcpy(s.buf[s.wlen..][0..n], data[0..n]);
        s.wlen += n;
        var rest = data[n..];
        if (rest.len == 0) return true;
        if (!s.flush(th)) return false;
        const direct = rest.len - rest.len % buf_size;
        if (direct > 0 and !s.writeNow(th, rest[0..direct])) return false;
        rest = rest[direct..];
        @memcpy(s.buf[0..rest.len], rest);
        s.wlen = rest.len;
        return true;
    }

    fn writeNow(s: *Stream, th: *Thread, data: []const u8) bool {
        s.writeOut(th, data) catch |e| {
            s.err = errnoOf(e);
            return false;
        };
        return true;
    }

    fn stdoutFailed(s: *Stream, h: *base.Host) bool {
        s.err = errnoOf(h.file_stdout.err orelse error.InputOutput);
        return false;
    }

    /// `fseek` then `ftell`: the new position, or null with `err` set.
    fn seek(s: *Stream, th: *Thread, whence: usize, offset: i64) ?u64 {
        if (!s.flush(th)) return null;
        const h = host(th);
        const io = h.io;
        if (s.host_stdout and h.stdout != &h.file_stdout.interface) {
            // The embedder took standard output, so there is no file.
            s.err = 29;
            return null;
        }
        const file = if (s.host_stdout) h.file_stdout.file else s.file;
        const logical: u64 = if (s.host_stdout) h.file_stdout.pos else switch (s.mode) {
            .reading => s.pos - (s.rend - s.rpos),
            else => s.pos,
        };
        const origin: u64 = switch (whence) {
            0 => 0,
            1 => logical,
            else => file.length(io) catch |e| {
                s.err = errnoOf(e);
                return null;
            },
        };
        const target = @as(i128, origin) + offset;
        if (target < 0 or target > std.math.maxInt(i64)) {
            s.err = 22;
            return null;
        }
        const t: u64 = @intCast(target);
        io.vtable.fileSeekTo(io.userdata, file, t) catch |e| {
            s.err = errnoOf(e);
            return null;
        };
        if (s.host_stdout) h.file_stdout.pos = t;
        s.rpos = 0;
        s.rend = 0;
        s.mode = .idle;
        s.eof = false;
        s.pos = t;
        return t;
    }
};

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

fn fileMeta(state: *State) ?*Table {
    const key = state.newString(handle_name) catch return null;
    const v = state.registry.getStr(key);
    return if (v.tag == .table) v.asTable() else null;
}

fn streamOf(u: *Userdata) *Stream {
    return @ptrCast(@alignCast(u.bytes().ptr));
}

/// `luaL_testudata(L, n, LUA_FILEHANDLE)`.
fn testStream(th: *Thread, v: Value) ?*Stream {
    if (v.tag != .userdata) return null;
    const u = v.asUserdata();
    const mt = u.metatable orelse return null;
    if (mt != fileMeta(th.state) or u.len != @sizeOf(Stream)) return null;
    return streamOf(u);
}

/// `tolstream`: `luaL_checkudata(L, n, LUA_FILEHANDLE)`.
fn checkStream(a: Args, n: u32) Error!*Stream {
    return testStream(a.th, a.get(n)) orelse a.typeError(n, handle_name);
}

/// `tofile`: an open file handle.
fn checkOpen(a: Args, n: u32) Error!*Stream {
    const s = try checkStream(a, n);
    if (s.kind == .closed) return aux.raise(a.th, "attempt to use a closed file", .{});
    return s;
}

/// `newprefile`: a new closed handle with the file metatable, pushed.
fn newHandle(th: *Thread) Error!*Stream {
    const state = th.state;
    const u = try Userdata.create(&state.heap, @sizeOf(Stream), 0);
    // Through `setMetatable`, so the handle's `__gc` closes it when it is
    // collected.
    state.setMetatable(.userdata(u), fileMeta(state));
    const s = streamOf(u);
    s.* = .{};
    th.push(.userdata(u));
    return s;
}

const OpenMode = struct { read: bool, write: bool, plus: bool, kind: u8 };

/// `l_checkmode`: "[rwa]%+?b*".
fn parseMode(mode: []const u8) ?OpenMode {
    if (mode.len == 0 or std.mem.findScalar(u8, "rwa", mode[0]) == null) return null;
    var i: usize = 1;
    const plus = i < mode.len and mode[i] == '+';
    if (plus) i += 1;
    for (mode[i..]) |c| if (c != 'b') return null;
    return .{ .read = mode[0] == 'r' or plus, .write = mode[0] != 'r' or plus, .plus = plus, .kind = mode[0] };
}

/// `fopen` into a closed handle.
fn openInto(th: *Thread, s: *Stream, name: []const u8, m: OpenMode) !void {
    const io = Stream.host(th).io;
    const cwd = Io.Dir.cwd();
    s.file = switch (m.kind) {
        'r' => try cwd.openFile(io, name, .{ .mode = if (m.plus) .read_write else .read_only }),
        else => try cwd.createFile(io, name, .{ .read = m.plus, .truncate = m.kind == 'w' }),
    };
    s.kind = .file;
    s.can_read = m.read;
    s.can_write = m.write;
    s.append = m.kind == 'a';
}

/// `opencheck`: opens `name` or raises "cannot open file".
fn openCheck(th: *Thread, name: []const u8, mode: []const u8) Error!*Stream {
    const s = try newHandle(th);
    openInto(th, s, cstr(name), parseMode(mode).?) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return aux.raise(th, "cannot open file '{s}' ({s})", .{ cstr(name), strerror(errnoOf(e)) });
    };
    return s;
}

/// The default input or output; raises "default input file is closed".
fn ioFile(th: *Thread, comptime key: []const u8) Error!Value {
    const v = th.state.registry.getStr(try th.state.newString(key));
    const s = testStream(th, v);
    if (s == null or s.?.kind == .closed) return aux.raise(th, "default {s} file is closed", .{key[4..]});
    return v;
}

/// `aux_close`: marks the handle closed and runs its close function,
/// pushing its results.
fn closeStream(th: *Thread, s: *Stream) Error!u32 {
    const io = Stream.host(th).io;
    const kind = s.kind;
    s.kind = .closed;
    switch (kind) {
        .file => {
            const ok = s.flush(th);
            s.file.close(io);
            if (!ok) return fileResultErrno(th, s.err, null);
            th.push(.true);
            return 1;
        },
        .popen => {
            _ = s.flush(th);
            s.file.close(io);
            const term = s.child.wait(io) catch |e| return fileResult(th, e, null);
            return execResult(th, term);
        },
        .std => {
            s.kind = .std;
            th.push(.nil);
            th.push(.string(try th.state.newString("cannot close standard file")));
            return 2;
        },
        .closed => unreachable,
    }
}

/// Flushes every open file handle, as C's `exit` and `popen` flush every
/// stream; nothing when the library was never opened. Handles the
/// collector already freed were closed by their finalizer.
pub fn flushAll(th: *Thread) void {
    const state = th.state;
    const mt = fileMeta(state) orelse return;
    var it = gc.objects(&state.heap);
    while (it.next()) |h| {
        if (h.tag != .userdata) continue;
        const u: *Userdata = @fieldParentPtr("header", h);
        if (u.metatable != mt or u.len != @sizeOf(Stream)) continue;
        const s = streamOf(u);
        if (s.kind != .closed) _ = s.flush(th);
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// The numeral being read by `readNumber`.
const Rn = struct {
    s: *Stream,
    th: *Thread,
    c: ?u8,
    n: usize = 0,
    overflow: bool = false,
    buf: [max_numeral]u8 = undefined,

    fn nextc(rn: *Rn) bool {
        if (rn.n >= max_numeral) {
            rn.overflow = true;
            return false;
        }
        rn.buf[rn.n] = rn.c.?;
        rn.n += 1;
        rn.s.rpos += 1;
        rn.c = rn.s.peek(rn.th);
        return true;
    }

    fn test2(rn: *Rn, set: *const [2]u8) bool {
        const c = rn.c orelse return false;
        return (c == set[0] or c == set[1]) and rn.nextc();
    }

    fn digits(rn: *Rn, hex: bool) usize {
        var count: usize = 0;
        while (rn.c) |c| {
            if (!(if (hex) std.ascii.isHex(c) else std.ascii.isDigit(c))) break;
            if (!rn.nextc()) break;
            count += 1;
        }
        return count;
    }
};

/// `read_number`: reads the longest prefix of a numeral, at most
/// `L_MAXLENNUM` bytes, leaving the next byte unread, and pushes its value
/// or nil.
fn readNumber(th: *Thread, s: *Stream) Error!bool {
    var rn: Rn = .{ .s = s, .th = th, .c = null };
    if (s.startRead(th)) {
        rn.c = s.peek(th);
        while (rn.c) |c| {
            if (!isSpace(c)) break;
            s.rpos += 1;
            rn.c = s.peek(th);
        }
        _ = rn.test2("-+");
        var count: usize = 0;
        var hex = false;
        if (rn.test2("00")) {
            if (rn.test2("xX")) hex = true else count = 1;
        }
        count += rn.digits(hex);
        if (rn.test2("..")) count += rn.digits(hex);
        if (count > 0 and rn.test2(if (hex) "pP" else "eE")) {
            _ = rn.test2("-+");
            _ = rn.digits(false);
        }
    }
    if (!rn.overflow) {
        if (number.parse(rn.buf[0..rn.n])) |v| {
            th.push(switch (v) {
                .int => |i| .int(i),
                .float => |f| .float(f),
            });
            return true;
        }
    }
    th.push(.nil);
    return false;
}

/// `test_eof`: pushes "" and says whether input remains.
fn testEof(th: *Thread, s: *Stream) Error!bool {
    const more = s.startRead(th) and s.peek(th) != null;
    th.push(.string(try th.state.newString("")));
    return more;
}

/// `read_line`: pushes the next line, without its newline when `chop`.
fn readLine(th: *Thread, s: *Stream, chop: bool) Error!bool {
    var b: aux.Buffer = .init(th.state);
    defer b.deinit();
    var newline = false;
    if (s.startRead(th)) {
        while (!newline) {
            if (s.rpos == s.rend and s.fill(th) == 0) break;
            const avail = s.buf[s.rpos..s.rend];
            const n = if (std.mem.findScalar(u8, avail, '\n')) |i| blk: {
                newline = true;
                break :blk i;
            } else avail.len;
            b.writer.writeAll(avail[0..n]) catch return error.OutOfMemory;
            s.rpos += n + @intFromBool(newline);
        }
    }
    if (newline and !chop) b.writer.writeByte('\n') catch return error.OutOfMemory;
    th.push(.string(try b.toString(th.state)));
    return newline or b.written().len > 0;
}

/// `read_all`: pushes the rest of the file.
fn readAll(th: *Thread, s: *Stream) Error!void {
    var b: aux.Buffer = .init(th.state);
    defer b.deinit();
    if (s.startRead(th)) {
        while (s.rpos < s.rend or s.fill(th) > 0) {
            b.writer.writeAll(s.buf[s.rpos..s.rend]) catch return error.OutOfMemory;
            s.rpos = s.rend;
        }
    }
    th.push(.string(try b.toString(th.state)));
}

/// `read_chars`: pushes up to `n` bytes and says whether it read any.
fn readChars(th: *Thread, s: *Stream, n: usize) Error!bool {
    var b: aux.Buffer = .init(th.state);
    defer b.deinit();
    var left = n;
    if (s.startRead(th)) {
        while (left > 0 and (s.rpos < s.rend or s.fill(th) > 0)) {
            const k = @min(left, s.rend - s.rpos);
            b.writer.writeAll(s.buf[s.rpos..][0..k]) catch return error.OutOfMemory;
            s.rpos += k;
            left -= k;
        }
    }
    th.push(.string(try b.toString(th.state)));
    return left < n;
}

/// `g_read`: reads by the formats from argument `first` on, pushing one
/// result each up to the first failure, which gives nil.
fn gRead(a: Args, s: *Stream, first: u32) Error!u32 {
    const th = a.th;
    const nargs = a.count() + 1 - first;
    s.err = 0;
    s.eof = false;
    var n: u32 = 0;
    var success = true;
    if (nargs == 0) {
        success = try readLine(th, s, true);
        n = 1;
    } else {
        try aux.checkStack(th, nargs + Thread.min_stack, "too many arguments");
        var i = first;
        while (i < first + nargs and success) : (i += 1) {
            const v = a.get(i);
            if (v.isNumber()) {
                const l = try a.checkInteger(i);
                if (l < 0) return aux.raise(th, "resulting string too large", .{});
                success = if (l == 0) try testEof(th, s) else try readChars(th, s, @intCast(l));
            } else {
                var p = (try a.checkString(i)).bytes();
                if (p.len > 0 and p[0] == '*') p = p[1..];
                switch (if (p.len > 0) p[0] else 0) {
                    'n' => success = try readNumber(th, s),
                    'l' => success = try readLine(th, s, true),
                    'L' => success = try readLine(th, s, false),
                    'a' => {
                        try readAll(th, s);
                        success = true;
                    },
                    else => return a.argError(i, "invalid format", .{}),
                }
            }
            n += 1;
        }
    }
    if (s.err != 0) return fileResultErrno(th, s.err, null);
    if (!success) th.stack[th.top - 1] = .nil;
    return n;
}

fn ioRead(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "read");
    const f = try ioFile(th, input_key);
    return gRead(a, testStream(th, f).?, 1);
}

fn fRead(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "read");
    return gRead(a, try checkOpen(a, 1), 2);
}

/// The iterator `lines` returns. Upvalues: the file, the number of formats,
/// whether to close the file at the end, then the formats.
fn ioReadline(th: *Thread, b: u32) Error!u32 {
    const up = th.stack[b - 1].asNativeClosure().upvalues();
    const s = testStream(th, up[0]).?;
    const n: u32 = @intCast(up[1].asInt());
    if (s.kind == .closed) return aux.raise(th, "file is already closed", .{});
    if (th.top == b) th.stack[b] = .nil;
    th.top = b + 1;
    try aux.checkStack(th, n, "too many arguments");
    for (up[3..][0..n]) |v| th.push(v);
    const r = try gRead(Args.init(th, b, "lines"), s, 2);
    const first = th.stack[th.top - r];
    if (!first.isFalsy()) return r;
    if (r > 1) {
        const msg = th.stack[th.top - r + 1];
        return aux.raise(th, "{s}", .{if (msg.isString()) msg.asString().bytes() else "?"});
    }
    if (!up[2].isFalsy()) {
        th.top = b;
        _ = try closeStream(th, s);
        th.top = b;
    }
    return 0;
}

/// `aux_lines`: the iterator over the file at argument 1 with the formats
/// after it.
fn auxLines(th: *Thread, a: Args, toclose: bool) Error!Value {
    const n = a.count() - 1;
    if (n > max_lines_args) return a.argError(max_lines_args + 2, "too many arguments", .{});
    const c = try Proto.NativeClosure.create(th.heap(), &ioReadline, @intCast(3 + n));
    const heap = th.heap();
    c.setUpvalue(heap, 0, a.get(1));
    c.setUpvalue(heap, 1, .int(n));
    c.setUpvalue(heap, 2, .boolean(toclose));
    for (0..n) |i| c.setUpvalue(heap, 3 + i, a.get(@intCast(2 + i)));
    return .nativeClosure(c);
}

fn fLines(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "lines");
    _ = try checkOpen(a, 1);
    th.push(try auxLines(th, a, false));
    return 1;
}

fn ioLines(th: *Thread, b: u32) Error!u32 {
    if (th.top == b) th.push(.nil);
    var a = Args.init(th, b, "lines");
    var toclose = false;
    if (a.get(1).isNil()) {
        th.stack[b] = th.state.registry.getStr(try th.state.newString(input_key));
        _ = try checkOpen(a, 1);
    } else {
        const name = try a.checkString(1);
        _ = try openCheck(th, name.bytes(), "r");
        th.stack[b] = th.stack[th.top - 1];
        th.top -= 1;
        toclose = true;
    }
    a = Args.init(th, b, "lines");
    const it = try auxLines(th, a, toclose);
    th.push(it);
    if (!toclose) return 1;
    th.push(.nil);
    th.push(.nil);
    th.push(th.stack[b]);
    return 4;
}

// ---------------------------------------------------------------------------
// Writing and the rest
// ---------------------------------------------------------------------------

/// `g_write`: writes the arguments from `first` on; the file is on top.
fn gWrite(a: Args, s: *Stream, first: u32) Error!u32 {
    const th = a.th;
    s.err = 0;
    var total: i64 = 0;
    var i = first;
    while (i <= a.count()) : (i += 1) {
        const v = a.get(i);
        var nb: [number.max_len]u8 = undefined;
        const bytes = if (v.isNumber()) aux.formatNumber(&nb, v) else (try a.checkString(i)).bytes();
        if (!s.write(th, bytes)) {
            const r = try fileResultErrno(th, s.err, null);
            th.push(.int(total));
            return r + 1;
        }
        total += @intCast(bytes.len);
    }
    return 1;
}

fn ioWrite(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "write");
    const f = try ioFile(th, output_key);
    th.push(f);
    return gWrite(a, testStream(th, f).?, 1);
}

fn fWrite(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "write");
    const s = try checkOpen(a, 1);
    th.push(th.stack[b]);
    return gWrite(a, s, 2);
}

fn fSeek(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "seek");
    const s = try checkOpen(a, 1);
    const names = [_][]const u8{ "set", "cur", "end" };
    const name = try a.optString(2, "cur");
    const whence = for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) break i;
    } else return a.argError(2, "invalid option '{s}'", .{name[0..@min(name.len, 80)]});
    const offset = try a.optInteger(3, 0);
    s.err = 0;
    const p = s.seek(th, whence, offset) orelse return fileResultErrno(th, s.err, null);
    th.push(.int(@intCast(p)));
    return 1;
}

fn fSetvbuf(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "setvbuf");
    const s = try checkOpen(a, 1);
    const name = (try a.checkString(2)).bytes();
    _ = try a.optInteger(3, aux.Buffer.inline_len);
    s.err = 0;
    if (std.mem.eql(u8, name, "no")) {
        // Only giving up the buffer flushes it.
        if (!s.flush(th)) return fileResultErrno(th, s.err, null);
        s.vbuf = .no;
    } else if (std.mem.eql(u8, name, "full")) {
        s.vbuf = .full;
    } else if (std.mem.eql(u8, name, "line")) {
        s.vbuf = .line;
    } else return a.argError(2, "invalid option '{s}'", .{name[0..@min(name.len, 80)]});
    th.push(.true);
    return 1;
}

fn flushResult(th: *Thread, s: *Stream) Error!u32 {
    s.err = 0;
    if (!s.flush(th)) return fileResultErrno(th, s.err, null);
    th.push(.true);
    return 1;
}

fn fFlush(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "flush");
    return flushResult(th, try checkOpen(a, 1));
}

fn ioFlush(th: *Thread, b: u32) Error!u32 {
    _ = b;
    const f = try ioFile(th, output_key);
    return flushResult(th, testStream(th, f).?);
}

fn fClose(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "close");
    return closeStream(th, try checkOpen(a, 1));
}

fn ioClose(th: *Thread, b: u32) Error!u32 {
    if (th.top == b) th.push(th.state.registry.getStr(try th.state.newString(output_key)));
    return fClose(th, b);
}

/// `__gc` and `__close`: closes the file unless it is closed already.
fn fGc(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "__gc");
    const s = try checkStream(a, 1);
    if (s.kind != .closed) {
        const top = th.top;
        _ = try closeStream(th, s);
        th.top = top;
    }
    return 0;
}

fn fTostring(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "tostring");
    const s = try checkStream(a, 1);
    if (s.kind == .closed) {
        th.push(.string(try th.state.newString("file (closed)")));
    } else {
        var buf: [64]u8 = undefined;
        const text = std.mem.print(&buf, "file (0x{x})", .{@intFromPtr(s)}) catch unreachable;
        th.push(.string(try th.state.newString(text)));
    }
    return 1;
}

fn ioType(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "type");
    try a.checkAny(1);
    const s = testStream(th, a.get(1));
    th.push(if (s) |st| .string(try th.state.newString(if (st.kind == .closed) "closed file" else "file")) else .nil);
    return 1;
}

fn ioOpen(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "open");
    const name = cstr((try a.checkString(1)).bytes());
    const mode = cstr(try a.optString(2, "r"));
    const s = try newHandle(th);
    const m = parseMode(mode) orelse return a.argError(2, "invalid mode", .{});
    openInto(th, s, name, m) catch |e| return fileResult(th, e, name);
    return 1;
}

/// `g_iofile`: sets the default input or output from a file name or a
/// handle, then returns it.
fn ioFileArg(th: *Thread, b: u32, comptime key: []const u8, comptime mode: []const u8) Error!u32 {
    const a = Args.init(th, b, key[4..]);
    const state = th.state;
    if (!a.isNoneOrNil(1)) {
        const v = a.get(1);
        if (v.isString() or v.isNumber()) {
            const name = try a.checkString(1);
            _ = try openCheck(th, name.bytes(), mode);
        } else {
            _ = try checkOpen(a, 1);
            th.push(v);
        }
        try state.registry.setStr(&state.heap, try state.newString(key), th.stack[th.top - 1]);
    }
    th.push(state.registry.getStr(try state.newString(key)));
    return 1;
}

fn ioInput(th: *Thread, b: u32) Error!u32 {
    return ioFileArg(th, b, input_key, "r");
}

fn ioOutput(th: *Thread, b: u32) Error!u32 {
    return ioFileArg(th, b, output_key, "w");
}

fn ioPopen(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "popen");
    const cmd = cstr((try a.checkString(1)).bytes());
    const mode = cstr(try a.optString(2, "r"));
    const s = try newHandle(th);
    const reading = std.mem.eql(u8, mode, "r");
    if (!reading and !std.mem.eql(u8, mode, "w")) return a.argError(2, "invalid mode", .{});
    flushAll(th);
    const io = Stream.host(th).io;
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = if (reading) .inherit else .pipe,
        .stdout = if (reading) .pipe else .inherit,
    }) catch |e| return fileResult(th, e, cmd);
    if (reading) {
        s.file = child.stdout.?;
        child.stdout = null;
    } else {
        s.file = child.stdin.?;
        child.stdin = null;
    }
    s.child = child;
    s.kind = .popen;
    s.can_read = reading;
    s.can_write = !reading;
    return 1;
}

fn ioTmpfile(th: *Thread, b: u32) Error!u32 {
    _ = b;
    const s = try newHandle(th);
    const io = Stream.host(th).io;
    var name: [15]u8 = undefined;
    const file = os.makeTemp(io, &name) catch |e| return fileResult(th, e, null);
    Io.Dir.cwd().deleteFile(io, &name) catch |e| {
        file.close(io);
        return fileResult(th, e, null);
    };
    s.file = file;
    s.kind = .file;
    s.can_read = true;
    s.can_write = true;
    return 1;
}

/// `createstdfile`: a standard stream handle, set in `lib` and, with a key,
/// in the registry.
fn createStd(th: *Thread, lib: *Table, comptime name: []const u8, key: ?[]const u8, init: Stream) Error!void {
    const state = th.state;
    const s = try newHandle(th);
    s.* = init;
    s.kind = .std;
    const v = th.stack[th.top - 1];
    th.top -= 1;
    if (key) |k| try state.registry.setStr(&state.heap, try state.newString(k), v);
    try aux.setField(state, lib, name, v);
}

/// Opens the library into the global `io`, with the file metatable and the
/// standard streams.
pub fn open(th: *Thread) Error!void {
    const state = th.state;
    const lib = try aux.newLib(state, .{
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
    try aux.setField(state, state.globals, "io", .table(lib));
    // `createmeta`, unless another state's library made it already.
    if (fileMeta(state) == null) {
        const mt = try aux.newLib(state, .{
            .{ "__gc", &fGc },
            .{ "__close", &fGc },
            .{ "__tostring", &fTostring },
        });
        try aux.setField(state, mt, "__name", .string(try state.newString(handle_name)));
        const methods = try aux.newLib(state, .{
            .{ "read", &fRead },
            .{ "write", &fWrite },
            .{ "lines", &fLines },
            .{ "flush", &fFlush },
            .{ "seek", &fSeek },
            .{ "close", &fClose },
            .{ "setvbuf", &fSetvbuf },
        });
        try aux.setField(state, mt, "__index", .table(methods));
        try state.registry.setStr(&state.heap, try state.newString(handle_name), .table(mt));
    }
    const io = base.getHost(th).io;
    try th.ensureStack(1);
    try createStd(th, lib, "stdin", input_key, .{
        .file = File.stdin(),
        .can_read = true,
        .interactive = File.stdin().isTty(io) catch false,
    });
    try createStd(th, lib, "stdout", output_key, .{
        .file = File.stdout(),
        .can_write = true,
        .host_stdout = true,
        .vbuf = if (File.stdout().isTty(io) catch false) .line else .full,
    });
    try createStd(th, lib, "stderr", null, .{ .file = File.stderr(), .can_write = true, .vbuf = .no });
}

test "files: read formats, the number reader, lines, buffering, and errno results" {
    // Cases from files.lua; expected values from the reference.
    try package.testing.expectChunk(&.{},
        \\local name = os.tmpname()
        \\local f = assert(io.open(name, "w"))
        \\assert(f:write("-12.3-\t-0xffff+  .3|5.E-3X  +234e+13E 0xDEADBEEFDEADBEEFx\n0x1.13Ap+3e\n") == f)
        \\f:write("1234", string.rep("0", 300), "\n", ".e+\t0.e;\t--;  0xX;\n", 3450, " ", 1.5, "\n")
        \\assert(f:close())
        \\f = assert(io.open(name))
        \\assert(f:read("n") == -12.3 and f:read(1) == "-")
        \\assert(f:read("n") == -0xffff and f:read(2) == "+ ")
        \\assert(f:read("n") == 0.3 and f:read(1) == "|")
        \\assert(f:read("n") == 5e-3 and f:read(1) == "X")
        \\assert(f:read("n") == 234e13 and f:read(1) == "E")
        \\assert(f:read("n") == 0Xdeadbeefdeadbeef and f:read(2) == "x\n")
        \\assert(f:read("n") == 0x1.13aP3 and f:read(1) == "e")
        \\assert(not f:read("n") and f:read("L"):find("^00*\n$"))
        \\assert(not f:read("n") and f:read(2) == "e+")
        \\assert(not f:read("n") and f:read(1) == ";")
        \\assert(not f:read("n") and f:read(2) == "-;")
        \\assert(not f:read("n") and f:read(1) == "X")
        \\assert(not f:read("n") and f:read(1) == ";")
        \\local a, b, c = f:read("n", "n", "l")
        \\assert(a == 3450 and math.type(a) == "integer" and b == 1.5 and c == "")
        \\assert(f:read(0) == nil and f:read("a") == "" and f:read("l") == nil)
        \\assert(f:seek("set", 1) == 1 and f:read(5) == "12.3-" and f:seek() == 6)
        \\assert(f:seek("end") > 300 and io.type(f) == "file")
        \\f:close()
        \\assert(io.type(f) == "closed file" and tostring(f) == "file (closed)" and not io.type({}))
        \\assert(select(2, pcall(f.read, f)) == "attempt to use a closed file")
        \\-- lines, with formats; io.lines closes its file at the end
        \\f = assert(io.open(name, "w")) f:write("a\n\nb 12 13\nlast") f:close()
        \\local it = io.lines(name, "L")
        \\assert(it() == "a\n" and it() == "\n" and it() == "b 12 13\n" and it() == "last" and it() == nil)
        \\assert(select(2, pcall(it)):find("file is already closed", 1, true))
        \\f = assert(io.open(name))
        \\local got = {}
        \\for l in f:lines() do got[#got + 1] = l end
        \\assert(#got == 4 and got[2] == "" and got[4] == "last" and io.type(f) == "file")
        \\f:seek("set", 5)
        \\local x, y = f:lines("n", "n")()
        \\assert(x == 12 and y == 13)
        \\f:close()
        \\-- buffering: two handles on one file
        \\local w = assert(io.open(name, "w"))
        \\local r = assert(io.open(name, "r"))
        \\w:write("x") r:seek("set") assert(r:read("a") == "")
        \\assert(w:setvbuf("line")) w:write("y\nz") r:seek("set") assert(r:read("a") == "xy\n")
        \\assert(w:setvbuf("no")) r:seek("set") assert(r:read("a") == "xy\nz")
        \\assert(w:setvbuf("full")) w:write("1") assert(w:flush()) r:seek("set") assert(r:read("a") == "xy\nz1")
        \\w:close() r:close()
        \\-- read and write on one handle; append
        \\f = assert(io.open(name, "w+")) f:write("hello world") f:seek("set", 6) assert(f:read(3) == "wor")
        \\f:write("X") f:seek("set") assert(f:read("a") == "hello worXd") f:close()
        \\f = assert(io.open(name, "a+")) f:write("!") f:seek("set") assert(f:read("a") == "hello worXd!") f:close()
        \\-- errors carry errno
        \\local n, msg, code = io.open(name .. "/x")
        \\assert(n == nil and msg == name .. "/x: Not a directory" and code == 20)
        \\n, msg, code = io.open("/nonexistent-dir/x", "w")
        \\assert(msg == "/nonexistent-dir/x: No such file or directory" and code == 2)
        \\n, msg, code = io.open(name):write("x")
        \\assert(n == nil and msg == "Bad file descriptor" and code == 9)
        \\assert(select(2, pcall(io.open, name, "rw")):find("invalid mode", 1, true))
        \\assert(not io.stdout:close() and select(2, io.stderr:close()) == "cannot close standard file")
        \\-- default files
        \\io.output(name) io.write("line1\n", 2, "\n") assert(io.close())
        \\assert(select(2, pcall(io.write, "x")):find("default output file is closed", 1, true))
        \\io.output(io.stdout)
        \\io.input(name) assert(io.read() == "line1" and io.read("n") == 2) io.close(io.input())
        \\assert(select(2, pcall(io.read)):find("default input file is closed", 1, true))
        \\io.input(io.stdin)
        \\assert(select(2, pcall(io.lines, name .. "x")):find("No such file or directory", 1, true))
        \\assert(select(2, pcall(io.lines, name, table.unpack({}, 1, 251))):find("too many arguments", 1, true))
        \\local tf = io.tmpfile() tf:write("tmp") tf:seek("set") assert(tf:read("a") == "tmp") tf:close()
        \\assert(os.remove(name))
        \\n, msg, code = os.remove(name)
        \\assert(n == nil and msg == name .. ": No such file or directory" and code == 2)
        \\return true
    );
}
