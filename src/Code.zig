//! The code generator: expression descriptors, registers, constants, jump
//! lists, and the instructions the parser emits, after reference Lua 5.5.1's
//! lcode.c. The parser (`Parser.zig`) drives it in one pass, so the code,
//! constants, and register use it produces are what `luac -l -l` lists for
//! the same source: the same constant folding, specialized opcodes
//! (`ADDI`, `ADDK`, `EQK`, `GETFIELD`, ...), and jump threading.
//!
//! Line information is one absolute line per instruction (`Proto.lineinfo`),
//! so PUC-Rio's relative and absolute line bookkeeping reduces to setting
//! the last instruction's line.

const std = @import("std");
const Value = @import("Value.zig");
const String = @import("String.zig");
const Proto = @import("Proto.zig");
const State = @import("State.zig");
const opcodes = @import("opcodes.zig");
const number = @import("number.zig");
const Parser = @import("Parser.zig");
// The reference's `pow`, so folded constants match the VM's `^`.
const libm = @import("lib/libm.zig");

const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;

pub const Error = Parser.Error;

/// The end of a jump list: an invalid address and an invalid link.
pub const no_jump: i32 = -1;
/// A `TESTSET` with this destination produces no value.
const no_reg: i32 = opcodes.max_a;
/// The largest constant index an RK operand can hold.
const max_index_rk = opcodes.max_b;
/// `LUA_MULTRET`.
pub const multret: i32 = -1;

/// What an expression descriptor holds; lparser.h's `expkind`.
pub const ExpKind = enum(u8) {
    /// No value: the empty end of an expression list.
    void,
    nil,
    true,
    false,
    /// A constant in `k`; `info` is its index.
    k,
    /// A float constant in `nval`.
    kflt,
    /// An integer constant in `ival`.
    kint,
    /// A string constant in `strval`.
    kstr,
    /// The value is in register `info`.
    nonreloc,
    /// A local variable: register `ridx`, active-variable index `vidx`.
    local,
    /// The named vararg parameter, as `local`.
    vargvar,
    /// A global: `info` indexes its declaration, or -1 for none.
    global,
    /// Upvalue `info`.
    upval,
    /// A compile-time constant: `info` indexes its declaration.
    @"const",
    /// `R[ind.t][R[ind.idx]]`.
    indexed,
    /// The vararg parameter indexed by register `ind.idx`.
    vargind,
    /// `UpValue[ind.t][K[ind.idx]]`.
    indexup,
    /// `R[ind.t][ind.idx]`, an integer key.
    indexi,
    /// `R[ind.t][K[ind.idx]]`, a short string key.
    indexstr,
    /// A comparison or test; `info` is its jump.
    jmp,
    /// The instruction at `info` can put its result in any register.
    reloc,
    /// A call; `info` is the instruction.
    call,
    /// `...`; `info` is the instruction.
    vararg,

    pub fn isVar(k: ExpKind) bool {
        return @intFromEnum(k) >= @intFromEnum(ExpKind.local) and @intFromEnum(k) <= @intFromEnum(ExpKind.indexstr);
    }

    pub fn isIndexed(k: ExpKind) bool {
        return @intFromEnum(k) >= @intFromEnum(ExpKind.indexed) and @intFromEnum(k) <= @intFromEnum(ExpKind.indexstr);
    }

    pub fn hasMultRet(k: ExpKind) bool {
        return k == .call or k == .vararg;
    }
};

/// An expression whose code may still be pending, plus its lists of jumps
/// out when true and when false (from `and`/`or`). lparser.h's `expdesc`,
/// with its union's members as separate fields.
pub const ExpDesc = struct {
    k: ExpKind = .void,
    info: i32 = 0,
    ival: i64 = 0,
    nval: f64 = 0,
    strval: *String = undefined,
    ind: Ind = .{},
    /// `local`, `vargvar`: the register and the active-variable index.
    ridx: u8 = 0,
    vidx: i32 = 0,
    /// Patch list of "exit when true".
    t: i32 = no_jump,
    /// Patch list of "exit when false".
    f: i32 = no_jump,

    pub const Ind = struct {
        /// The key: a register, a constant index, or the integer.
        idx: i32 = 0,
        /// The table: a register or an upvalue.
        t: u8 = 0,
        /// A read-only global.
        ro: bool = false,
        /// The key's constant index when it is a string, else -1.
        keystr: i32 = -1,
    };

    pub fn init(k: ExpKind, info: i32) ExpDesc {
        return .{ .k = k, .info = info };
    }

    inline fn hasJumps(e: *const ExpDesc) bool {
        return e.t != e.f;
    }
};

/// Variable kinds, lparser.h's `VDKREG` .. `GDKCONST`.
pub const VarKind = struct {
    pub const reg: u8 = 0;
    pub const constant: u8 = 1;
    pub const vararg_param: u8 = 2;
    pub const to_close: u8 = 3;
    /// A compile-time constant: no register.
    pub const ctc: u8 = 4;
    pub const global_reg: u8 = 5;
    pub const global_const: u8 = 6;

    pub fn inReg(kind: u8) bool {
        return kind <= to_close;
    }

    pub fn isGlobal(kind: u8) bool {
        return kind >= global_reg;
    }
};

/// Binary operators, in lcode.h's `ORDER OPR`.
pub const BinOpr = enum(u8) {
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    idiv,
    band,
    bor,
    bxor,
    shl,
    shr,
    concat,
    eq,
    lt,
    le,
    ne,
    gt,
    ge,
    @"and",
    @"or",
    none,

    fn foldable(o: BinOpr) bool {
        return @intFromEnum(o) <= @intFromEnum(BinOpr.shr);
    }
};

pub const UnOpr = enum(u8) { minus, bnot, not, len, none };

/// A block being compiled; lparser.c's `BlockCnt`.
pub const BlockCnt = struct {
    previous: ?*BlockCnt = null,
    /// Index of the block's first label.
    firstlabel: u32 = 0,
    /// Index of the block's first pending goto.
    firstgoto: u32 = 0,
    /// Active declarations at block entry.
    nactvar: i32 = 0,
    /// Some variable of the block is an upvalue or to be closed.
    upval: bool = false,
    /// 1 for a loop, 2 for a loop with pending breaks.
    isloop: u8 = 0,
    /// Inside the scope of a to-be-closed variable.
    insidetbc: bool = false,
};

/// The constant cache's key: lcode.c keys its cache table by the constant
/// itself, by a perturbed float for floats, and by unique objects for nil
/// and float zero.
const KKey = struct {
    tag: enum(u8) { string, int, float, true, false, nil, zero },
    bits: u64,
};

/// A function being compiled; lparser.h's `FuncState`. Its lists move into
/// the prototype when the function closes.
pub const FuncState = struct {
    f: *Proto,
    /// The enclosing function.
    prev: ?*FuncState = null,
    ls: *Parser,
    /// The innermost block.
    bl: ?*BlockCnt = null,
    insts: std.ArrayList(Instruction) = .empty,
    lines: std.ArrayList(u32) = .empty,
    ks: std.ArrayList(Value) = .empty,
    protos: std.ArrayList(*Proto) = .empty,
    locvars: std.ArrayList(Proto.LocVar) = .empty,
    upvals: std.ArrayList(Proto.UpvalDesc) = .empty,
    kcache: std.AutoHashMapUnmanaged(KKey, u32) = .empty,
    /// The last jump target (a "label").
    lasttarget: i32 = 0,
    /// Index of the function's first active variable in the parser's list.
    firstlocal: u32 = 0,
    /// Index of the function's first label.
    firstlabel: u32 = 0,
    /// Active variable declarations.
    nactvar: i32 = 0,
    /// The first free register.
    freereg: i32 = 0,
    /// The function must close upvalues when returning.
    needclose: bool = false,

    pub fn deinit(fs: *FuncState) void {
        const gpa = fs.ls.gpa;
        fs.insts.deinit(gpa);
        fs.lines.deinit(gpa);
        fs.ks.deinit(gpa);
        fs.protos.deinit(gpa);
        fs.locvars.deinit(gpa);
        fs.upvals.deinit(gpa);
        fs.kcache.deinit(gpa);
        fs.* = undefined;
    }

    /// The next instruction's position.
    pub inline fn pc(fs: *const FuncState) i32 {
        return @intCast(fs.insts.items.len);
    }

    pub inline fn inst(fs: *FuncState, at: i32) *Instruction {
        return &fs.insts.items[@intCast(at)];
    }

    fn checkLimit(fs: *FuncState, v: i32, l: i32, what: []const u8) Error!void {
        if (v > l) return fs.ls.errorLimit(fs, l, what);
    }

    /// The constant value of a compile-time constant variable.
    fn const2val(fs: *FuncState, e: *const ExpDesc) *Value {
        return &fs.ls.actvar.items[@intCast(e.info)].k;
    }

    /// The expression's value if it is a constant, for `<const>` locals.
    pub fn exp2const(fs: *FuncState, e: *const ExpDesc, v: *Value) bool {
        if (e.hasJumps()) return false;
        switch (e.k) {
            .false => v.* = .false,
            .true => v.* = .true,
            .nil => v.* = .nil,
            .kstr => v.* = .string(e.strval),
            .@"const" => v.* = fs.const2val(e).*,
            else => return toNumeral(e, v),
        }
        return true;
    }

    /// The previous instruction, or null when a jump may target the
    /// current position (so no peephole optimization may look back).
    fn previousInstruction(fs: *FuncState) ?*Instruction {
        if (fs.pc() > fs.lasttarget) return fs.inst(fs.pc() - 1);
        return null;
    }

    /// `LOADNIL` for `n` registers from `from`, merged into a previous
    /// `LOADNIL` when the ranges touch.
    pub fn nil(fs: *FuncState, from_: i32, n: i32) Error!void {
        var from = from_;
        var l = from + n - 1;
        if (fs.previousInstruction()) |prev| {
            if (opcodes.op(prev.*) == .loadnil) {
                const pfrom: i32 = opcodes.a(prev.*);
                const pl = pfrom + opcodes.b(prev.*);
                if ((pfrom <= from and from <= pl + 1) or (from <= pfrom and pfrom <= l + 1)) {
                    if (pfrom < from) from = pfrom;
                    if (pl > l) l = pl;
                    setA(prev, from);
                    setB(prev, l - from);
                    return;
                }
            }
        }
        _ = try fs.codeAbc(.loadnil, from, n - 1, 0);
    }

    /// The destination of the jump at `at`, or `no_jump` at a list's end.
    fn getJump(fs: *FuncState, at: i32) i32 {
        const offset = opcodes.sj(fs.inst(at).*);
        if (offset == no_jump) return no_jump;
        return at + 1 + offset;
    }

    fn fixJump(fs: *FuncState, at: i32, dest: i32) Error!void {
        const offset = dest - (at + 1);
        std.debug.assert(dest != no_jump);
        if (!(-opcodes.offset_sj <= offset and offset <= opcodes.max_sj - opcodes.offset_sj))
            return fs.ls.syntaxError("control structure too long");
        const j = fs.inst(at);
        std.debug.assert(opcodes.op(j.*) == .jmp);
        j.* = opcodes.isj(.jmp, offset);
    }

    /// Appends jump list `l2` to `l1`.
    pub fn concat(fs: *FuncState, l1: *i32, l2: i32) Error!void {
        if (l2 == no_jump) return;
        if (l1.* == no_jump) {
            l1.* = l2;
            return;
        }
        var list = l1.*;
        while (true) {
            const next = fs.getJump(list);
            if (next == no_jump) break;
            list = next;
        }
        try fs.fixJump(list, l2);
    }

    /// A jump to be patched later.
    pub fn jump(fs: *FuncState) Error!i32 {
        return fs.code(opcodes.isj(.jmp, no_jump));
    }

    pub fn ret(fs: *FuncState, first: i32, nret: i32) Error!void {
        const o: OpCode = switch (nret) {
            0 => .return0,
            1 => .return1,
            else => .@"return",
        };
        try fs.checkLimit(nret + 1, opcodes.max_b, "returns");
        _ = try fs.codeAbc(o, first, nret + 1, 0);
    }

    fn condJump(fs: *FuncState, o: OpCode, a_: i32, b_: i32, c_: i32, k_: bool) Error!i32 {
        _ = try fs.codeAbck(o, a_, b_, c_, k_);
        return fs.jump();
    }

    /// The current position, marked as a jump target.
    pub fn getLabel(fs: *FuncState) i32 {
        fs.lasttarget = fs.pc();
        return fs.pc();
    }

    /// The instruction controlling the jump at `at`: its test, or itself.
    fn getJumpControl(fs: *FuncState, at: i32) *Instruction {
        if (at >= 1 and opcodes.props[@intFromEnum(opcodes.op(fs.inst(at - 1).*))].is_test) return fs.inst(at - 1);
        return fs.inst(at);
    }

    /// Points the `TESTSET` controlling jump `node` at register `reg`, or
    /// turns it into a `TEST` when `reg` is `no_reg` or already holds the
    /// value. False when the control is not a `TESTSET`.
    fn patchTestReg(fs: *FuncState, node: i32, reg: i32) bool {
        const i = fs.getJumpControl(node);
        if (opcodes.op(i.*) != .testset) return false;
        if (reg != no_reg and reg != opcodes.b(i.*)) {
            setA(i, reg);
        } else {
            i.* = opcodes.abc(.@"test", opcodes.b(i.*), 0, 0, opcodes.k(i.*));
        }
        return true;
    }

    fn removeValues(fs: *FuncState, list_: i32) void {
        var list = list_;
        while (list != no_jump) : (list = fs.getJump(list)) _ = fs.patchTestReg(list, no_reg);
    }

    /// Patches a jump list: tests that produce values jump to `vtarget`
    /// with their value in `reg`; the others jump to `dtarget`.
    fn patchListAux(fs: *FuncState, list_: i32, vtarget: i32, reg: i32, dtarget: i32) Error!void {
        var list = list_;
        while (list != no_jump) {
            const next = fs.getJump(list);
            if (fs.patchTestReg(list, reg)) {
                try fs.fixJump(list, vtarget);
            } else {
                try fs.fixJump(list, dtarget);
            }
            list = next;
        }
    }

    pub fn patchList(fs: *FuncState, list: i32, target: i32) Error!void {
        std.debug.assert(target <= fs.pc());
        try fs.patchListAux(list, target, no_reg, target);
    }

    pub fn patchToHere(fs: *FuncState, list: i32) Error!void {
        const here = fs.getLabel();
        try fs.patchList(list, here);
    }

    /// A jump to `target`.
    pub fn jumpTo(fs: *FuncState, target: i32) Error!void {
        try fs.patchList(try fs.jump(), target);
    }

    fn removeLastInstruction(fs: *FuncState) void {
        fs.insts.items.len -= 1;
        fs.lines.items.len -= 1;
    }

    /// Emits `i` with the line of the last token read.
    pub fn code(fs: *FuncState, i: Instruction) Error!i32 {
        const gpa = fs.ls.gpa;
        try fs.insts.ensureUnusedCapacity(gpa, 1);
        try fs.lines.ensureUnusedCapacity(gpa, 1);
        fs.insts.appendAssumeCapacity(i);
        fs.lines.appendAssumeCapacity(fs.ls.lastline);
        return fs.pc() - 1;
    }

    pub fn codeAbck(fs: *FuncState, o: OpCode, a_: i32, b_: i32, c_: i32, k_: bool) Error!i32 {
        std.debug.assert(opcodes.props[@intFromEnum(o)].mode == .iABC);
        return fs.code(opcodes.abc(o, @intCast(a_), @intCast(b_), @intCast(c_), k_));
    }

    pub fn codeAbc(fs: *FuncState, o: OpCode, a_: i32, b_: i32, c_: i32) Error!i32 {
        return fs.codeAbck(o, a_, b_, c_, false);
    }

    pub fn codevAbck(fs: *FuncState, o: OpCode, a_: i32, b_: i32, c_: i32, k_: bool) Error!i32 {
        std.debug.assert(opcodes.props[@intFromEnum(o)].mode == .ivABC);
        return fs.code(opcodes.vabc(o, @intCast(a_), @intCast(b_), @intCast(c_), k_));
    }

    pub fn codeABx(fs: *FuncState, o: OpCode, a_: i32, bx_: i32) Error!i32 {
        return fs.code(opcodes.abx(o, @intCast(a_), @intCast(bx_)));
    }

    fn codeAsBx(fs: *FuncState, o: OpCode, a_: i32, sbx_: i32) Error!i32 {
        return fs.code(opcodes.asbx(o, @intCast(a_), sbx_));
    }

    fn codeExtraArg(fs: *FuncState, ax_: i32) Error!i32 {
        return fs.code(opcodes.iax(.extraarg, @intCast(ax_)));
    }

    /// Loads constant `kidx`, with `LOADKX` when it does not fit in Bx.
    fn codeK(fs: *FuncState, reg: i32, kidx: i32) Error!i32 {
        if (kidx <= opcodes.max_bx) return fs.codeABx(.loadk, reg, kidx);
        const p = try fs.codeABx(.loadkx, reg, 0);
        _ = try fs.codeExtraArg(kidx);
        return p;
    }

    /// Makes room for `n` more registers, tracking `maxstacksize`.
    pub fn checkStack(fs: *FuncState, n: i32) Error!void {
        const newstack = fs.freereg + n;
        if (newstack > fs.f.maxstacksize) {
            try fs.checkLimit(newstack, opcodes.max_registers, "registers");
            fs.f.maxstacksize = @intCast(newstack);
        }
    }

    pub fn reserveRegs(fs: *FuncState, n: i32) Error!void {
        try fs.checkStack(n);
        fs.freereg += n;
    }

    /// Frees `reg` if it is a temporary, not a local variable.
    fn freeReg(fs: *FuncState, reg: i32) void {
        if (reg >= fs.ls.nvarstack(fs)) {
            fs.freereg -= 1;
            std.debug.assert(reg == fs.freereg);
        }
    }

    fn freeRegs(fs: *FuncState, r1: i32, r2: i32) void {
        if (r1 > r2) {
            fs.freeReg(r1);
            fs.freeReg(r2);
        } else {
            fs.freeReg(r2);
            fs.freeReg(r1);
        }
    }

    fn freeExp(fs: *FuncState, e: *const ExpDesc) void {
        if (e.k == .nonreloc) fs.freeReg(e.info);
    }

    fn freeExps(fs: *FuncState, e1: *const ExpDesc, e2: *const ExpDesc) void {
        const r1 = if (e1.k == .nonreloc) e1.info else -1;
        const r2 = if (e2.k == .nonreloc) e2.info else -1;
        fs.freeRegs(r1, r2);
    }

    fn addK(fs: *FuncState, v: Value) Error!i32 {
        try fs.ks.append(fs.ls.gpa, v);
        return @intCast(fs.ks.items.len - 1);
    }

    /// The index of constant `v`, reused through the cache under `key`.
    fn k2proto(fs: *FuncState, key: KKey, v: Value) Error!i32 {
        if (fs.kcache.get(key)) |idx| return @intCast(idx);
        const idx = try fs.addK(v);
        try fs.kcache.put(fs.ls.gpa, key, @intCast(idx));
        return idx;
    }

    fn stringK(fs: *FuncState, s: *String) Error!i32 {
        return fs.k2proto(.{ .tag = .string, .bits = @intFromPtr(s) }, .string(s));
    }

    fn intK(fs: *FuncState, n: i64) Error!i32 {
        return fs.k2proto(.{ .tag = .int, .bits = @bitCast(n) }, .int(n));
    }

    /// A float constant. Like lcode.c, the cache key perturbs the float by
    /// its smallest significant fraction so integral floats do not collide
    /// with integers; a key that is still integral, or that collides,
    /// gets a fresh entry.
    fn numberK(fs: *FuncState, r: f64) Error!i32 {
        const o: Value = .float(r);
        if (r == 0) return fs.k2proto(.{ .tag = .zero, .bits = 0 }, o);
        const q = std.math.ldexp(@as(f64, 1.0), -std.math.floatMantissaBits(f64));
        const key = r * (1 + q);
        if (number.floatToInt(key, .exact) == null) {
            const n = try fs.k2proto(.{ .tag = .float, .bits = @bitCast(key) }, o);
            if (Value.rawEquals(fs.ks.items[@intCast(n)], o)) return n;
        }
        return fs.addK(o);
    }

    fn boolF(fs: *FuncState) Error!i32 {
        return fs.k2proto(.{ .tag = .false, .bits = 0 }, .false);
    }

    fn boolT(fs: *FuncState) Error!i32 {
        return fs.k2proto(.{ .tag = .true, .bits = 0 }, .true);
    }

    fn nilK(fs: *FuncState) Error!i32 {
        return fs.k2proto(.{ .tag = .nil, .bits = 0 }, .nil);
    }

    pub fn int(fs: *FuncState, reg: i32, i: i64) Error!void {
        if (fitsBx(i)) {
            _ = try fs.codeAsBx(.loadi, reg, @intCast(i));
        } else {
            _ = try fs.codeK(reg, try fs.intK(i));
        }
    }

    fn float(fs: *FuncState, reg: i32, f: f64) Error!void {
        if (number.floatToInt(f, .exact)) |fi| {
            if (fitsBx(fi)) {
                _ = try fs.codeAsBx(.loadf, reg, @intCast(fi));
                return;
            }
        }
        _ = try fs.codeK(reg, try fs.numberK(f));
    }

    /// Puts the global's value in a register and checks that it is nil
    /// (`ERRNNIL`), for `global` declarations with initializers. `kidx` is
    /// the constant index of the name.
    pub fn codeCheckGlobal(fs: *FuncState, v: *ExpDesc, kidx: i32, line: u32) Error!void {
        _ = try fs.exp2anyreg(v);
        fs.fixLine(line);
        const kk = if (kidx >= opcodes.max_bx) 0 else kidx + 1;
        _ = try fs.codeABx(.errnnil, v.info, kk);
        fs.fixLine(line);
        fs.freeExp(v);
    }

    /// Fixes a multi-result expression to return `nresults` values.
    pub fn setReturns(fs: *FuncState, e: *ExpDesc, nresults: i32) Error!void {
        const i = fs.inst(e.info);
        try fs.checkLimit(nresults + 1, opcodes.max_c, "multiple results");
        setC(i, nresults + 1);
        if (e.k == .vararg) {
            setA(i, fs.freereg);
            try fs.reserveRegs(1);
        }
    }

    pub fn setMultRet(fs: *FuncState, e: *ExpDesc) Error!void {
        return fs.setReturns(e, multret);
    }

    fn str2K(fs: *FuncState, e: *ExpDesc) Error!i32 {
        std.debug.assert(e.k == .kstr);
        e.info = try fs.stringK(e.strval);
        e.k = .k;
        return e.info;
    }

    /// Fixes a multi-result expression to one result.
    pub fn setOneRet(fs: *FuncState, e: *ExpDesc) void {
        if (e.k == .call) {
            e.k = .nonreloc;
            e.info = opcodes.a(fs.inst(e.info).*);
        } else if (e.k == .vararg) {
            setC(fs.inst(e.info), 2);
            e.k = .reloc;
        }
    }

    /// The vararg parameter becomes a real local: the function needs its
    /// vararg table.
    pub fn vapar2local(fs: *FuncState, v: *ExpDesc) void {
        fs.f.flags.vararg_table = true;
        v.k = .local;
    }

    /// Makes sure `e` is not a variable.
    pub fn dischargeVars(fs: *FuncState, e: *ExpDesc) Error!void {
        switch (e.k) {
            .@"const" => const2exp(fs.const2val(e).*, e),
            .vargvar, .local => {
                if (e.k == .vargvar) fs.vapar2local(e);
                e.info = e.ridx;
                e.k = .nonreloc;
            },
            .upval => {
                e.info = try fs.codeAbc(.getupval, 0, e.info, 0);
                e.k = .reloc;
            },
            .indexup => {
                e.info = try fs.codeAbc(.gettabup, 0, e.ind.t, e.ind.idx);
                e.k = .reloc;
            },
            .indexi => {
                fs.freeReg(e.ind.t);
                e.info = try fs.codeAbc(.geti, 0, e.ind.t, e.ind.idx);
                e.k = .reloc;
            },
            .indexstr => {
                fs.freeReg(e.ind.t);
                e.info = try fs.codeAbc(.getfield, 0, e.ind.t, e.ind.idx);
                e.k = .reloc;
            },
            .indexed => {
                fs.freeRegs(e.ind.t, e.ind.idx);
                e.info = try fs.codeAbc(.gettable, 0, e.ind.t, e.ind.idx);
                e.k = .reloc;
            },
            .vargind => {
                fs.freeRegs(e.ind.t, e.ind.idx);
                e.info = try fs.codeAbc(.getvarg, 0, e.ind.t, e.ind.idx);
                e.k = .reloc;
            },
            .vararg, .call => fs.setOneRet(e),
            else => {},
        }
    }

    /// Puts the value of `e` in register `reg`.
    fn discharge2reg(fs: *FuncState, e: *ExpDesc, reg: i32) Error!void {
        try fs.dischargeVars(e);
        switch (e.k) {
            .nil => try fs.nil(reg, 1),
            .false => _ = try fs.codeAbc(.loadfalse, reg, 0, 0),
            .true => _ = try fs.codeAbc(.loadtrue, reg, 0, 0),
            .kstr, .k => {
                if (e.k == .kstr) _ = try fs.str2K(e);
                _ = try fs.codeK(reg, e.info);
            },
            .kflt => try fs.float(reg, e.nval),
            .kint => try fs.int(reg, e.ival),
            .reloc => setA(fs.inst(e.info), reg),
            .nonreloc => if (reg != e.info) {
                _ = try fs.codeAbc(.move, reg, e.info, 0);
            },
            else => {
                std.debug.assert(e.k == .jmp);
                return;
            },
        }
        e.info = reg;
        e.k = .nonreloc;
    }

    fn discharge2anyreg(fs: *FuncState, e: *ExpDesc) Error!void {
        if (e.k != .nonreloc) {
            try fs.reserveRegs(1);
            try fs.discharge2reg(e, fs.freereg - 1);
        }
    }

    fn codeLoadBool(fs: *FuncState, a_: i32, o: OpCode) Error!i32 {
        _ = fs.getLabel();
        return fs.codeAbc(o, a_, 0, 0);
    }

    /// Whether a jump list has a jump that produces no value or an
    /// inverted one.
    fn needValue(fs: *FuncState, list_: i32) bool {
        var list = list_;
        while (list != no_jump) : (list = fs.getJump(list)) {
            if (opcodes.op(fs.getJumpControl(list).*) != .testset) return true;
        }
        return false;
    }

    /// Puts the whole value of `e`, jump lists included, in `reg`.
    fn exp2reg(fs: *FuncState, e: *ExpDesc, reg: i32) Error!void {
        try fs.discharge2reg(e, reg);
        if (e.k == .jmp) try fs.concat(&e.t, e.info);
        if (e.hasJumps()) {
            var p_f: i32 = no_jump;
            var p_t: i32 = no_jump;
            if (fs.needValue(e.t) or fs.needValue(e.f)) {
                const fj = if (e.k == .jmp) no_jump else try fs.jump();
                p_f = try fs.codeLoadBool(reg, .lfalseskip);
                p_t = try fs.codeLoadBool(reg, .loadtrue);
                try fs.patchToHere(fj);
            }
            const final = fs.getLabel();
            try fs.patchListAux(e.f, final, reg, p_f);
            try fs.patchListAux(e.t, final, reg, p_t);
        }
        e.f = no_jump;
        e.t = no_jump;
        e.info = reg;
        e.k = .nonreloc;
    }

    pub fn exp2nextreg(fs: *FuncState, e: *ExpDesc) Error!void {
        try fs.dischargeVars(e);
        fs.freeExp(e);
        try fs.reserveRegs(1);
        try fs.exp2reg(e, fs.freereg - 1);
    }

    pub fn exp2anyreg(fs: *FuncState, e: *ExpDesc) Error!i32 {
        try fs.dischargeVars(e);
        if (e.k == .nonreloc) {
            if (!e.hasJumps()) return e.info;
            if (e.info >= fs.ls.nvarstack(fs)) {
                try fs.exp2reg(e, e.info);
                return e.info;
            }
            // A local with jumps cannot take the jump values; use a new
            // register.
        }
        try fs.exp2nextreg(e);
        return e.info;
    }

    /// Makes `e` a register, an upvalue, or the vararg parameter.
    pub fn exp2anyregup(fs: *FuncState, e: *ExpDesc) Error!void {
        if ((e.k != .upval and e.k != .vargvar) or e.hasJumps()) _ = try fs.exp2anyreg(e);
    }

    /// Makes `e` a register or a constant.
    pub fn exp2val(fs: *FuncState, e: *ExpDesc) Error!void {
        if (e.k == .jmp or e.hasJumps()) {
            _ = try fs.exp2anyreg(e);
        } else {
            try fs.dischargeVars(e);
        }
    }

    /// Makes `e` a constant with an RK-sized index, if it is a constant.
    fn exp2K(fs: *FuncState, e: *ExpDesc) Error!bool {
        if (e.hasJumps()) return false;
        const info: i32 = switch (e.k) {
            .true => try fs.boolT(),
            .false => try fs.boolF(),
            .nil => try fs.nilK(),
            .kint => try fs.intK(e.ival),
            .kflt => try fs.numberK(e.nval),
            .kstr => try fs.stringK(e.strval),
            .k => e.info,
            else => return false,
        };
        if (info <= max_index_rk) {
            e.k = .k;
            e.info = info;
            return true;
        }
        return false;
    }

    /// Makes `e` an RK operand; true when it is a constant.
    fn exp2Rk(fs: *FuncState, e: *ExpDesc) Error!bool {
        if (try fs.exp2K(e)) return true;
        _ = try fs.exp2anyreg(e);
        return false;
    }

    fn codeAbRk(fs: *FuncState, o: OpCode, a_: i32, b_: i32, ec: *ExpDesc) Error!void {
        const kk = try fs.exp2Rk(ec);
        _ = try fs.codeAbck(o, a_, b_, ec.info, kk);
    }

    /// Stores `ex` into variable `v`.
    pub fn storeVar(fs: *FuncState, v: *ExpDesc, ex: *ExpDesc) Error!void {
        switch (v.k) {
            .local => {
                fs.freeExp(ex);
                return fs.exp2reg(ex, v.ridx);
            },
            .upval => {
                const e = try fs.exp2anyreg(ex);
                _ = try fs.codeAbc(.setupval, e, v.info, 0);
            },
            .indexup => try fs.codeAbRk(.settabup, v.ind.t, v.ind.idx, ex),
            .indexi => try fs.codeAbRk(.seti, v.ind.t, v.ind.idx, ex),
            .indexstr => try fs.codeAbRk(.setfield, v.ind.t, v.ind.idx, ex),
            .vargind, .indexed => {
                if (v.k == .vargind) fs.f.flags.vararg_table = true;
                try fs.codeAbRk(.settable, v.ind.t, v.ind.idx, ex);
            },
            else => unreachable,
        }
        fs.freeExp(ex);
    }

    fn negateCondition(fs: *FuncState, e: *ExpDesc) void {
        const i = fs.getJumpControl(e.info);
        std.debug.assert(opcodes.props[@intFromEnum(opcodes.op(i.*))].is_test);
        std.debug.assert(opcodes.op(i.*) != .testset);
        std.debug.assert(opcodes.op(i.*) != .@"test");
        setK(i, !opcodes.k(i.*));
    }

    /// A jump taken when `e` is `cond`. A `NOT` just before is removed and
    /// the condition inverted.
    fn jumpOnCond(fs: *FuncState, e: *ExpDesc, cond: bool) Error!i32 {
        if (e.k == .reloc) {
            const ie = fs.inst(e.info).*;
            if (opcodes.op(ie) == .not) {
                fs.removeLastInstruction();
                return fs.condJump(.@"test", opcodes.b(ie), 0, 0, !cond);
            }
        }
        try fs.discharge2anyreg(e);
        fs.freeExp(e);
        return fs.condJump(.testset, no_reg, e.info, 0, cond);
    }

    /// Falls through when `e` is true, jumps otherwise.
    pub fn goIfTrue(fs: *FuncState, e: *ExpDesc) Error!void {
        try fs.dischargeVars(e);
        const at: i32 = switch (e.k) {
            .jmp => blk: {
                fs.negateCondition(e);
                break :blk e.info;
            },
            .k, .kflt, .kint, .kstr, .true => no_jump,
            else => try fs.jumpOnCond(e, false),
        };
        try fs.concat(&e.f, at);
        try fs.patchToHere(e.t);
        e.t = no_jump;
    }

    /// Falls through when `e` is false, jumps otherwise.
    fn goIfFalse(fs: *FuncState, e: *ExpDesc) Error!void {
        try fs.dischargeVars(e);
        const at: i32 = switch (e.k) {
            .jmp => e.info,
            .nil, .false => no_jump,
            else => try fs.jumpOnCond(e, true),
        };
        try fs.concat(&e.t, at);
        try fs.patchToHere(e.f);
        e.f = no_jump;
    }

    fn codeNot(fs: *FuncState, e: *ExpDesc) Error!void {
        switch (e.k) {
            .nil, .false => e.k = .true,
            .k, .kflt, .kint, .kstr, .true => e.k = .false,
            .jmp => fs.negateCondition(e),
            .reloc, .nonreloc => {
                try fs.discharge2anyreg(e);
                fs.freeExp(e);
                e.info = try fs.codeAbc(.not, 0, e.info, 0);
                e.k = .reloc;
            },
            else => unreachable,
        }
        std.mem.swap(i32, &e.f, &e.t);
        fs.removeValues(e.f);
        fs.removeValues(e.t);
    }

    /// A short string constant with an RK-sized index.
    fn isKstr(fs: *FuncState, e: *const ExpDesc) bool {
        return e.k == .k and !e.hasJumps() and e.info <= max_index_rk and
            fs.ks.items[@intCast(e.info)].tag == .short_string;
    }

    /// Emits `SELF` or its equivalent, turning `e` into `e.key(e,`.
    pub fn self(fs: *FuncState, e: *ExpDesc, key: *ExpDesc) Error!void {
        _ = try fs.exp2anyreg(e);
        const ereg = e.info;
        fs.freeExp(e);
        const base = fs.freereg;
        e.info = base;
        e.k = .nonreloc;
        try fs.reserveRegs(2);
        std.debug.assert(key.k == .kstr);
        if (key.strval.isShort() and try fs.exp2K(key)) {
            _ = try fs.codeAbck(.self, base, ereg, key.info, false);
        } else {
            _ = try fs.exp2anyreg(key);
            _ = try fs.codeAbc(.move, base + 1, ereg, 0);
            _ = try fs.codeAbc(.gettable, base, ereg, key.info);
        }
        fs.freeExp(key);
    }

    /// Makes `t` the indexed expression `t[k]`. `t` is in a register, an
    /// upvalue, or the vararg parameter.
    pub fn indexed(fs: *FuncState, t: *ExpDesc, k: *ExpDesc) Error!void {
        var keystr: i32 = -1;
        if (k.k == .kstr) keystr = try fs.str2K(k);
        std.debug.assert(!t.hasJumps());
        std.debug.assert(t.k == .local or t.k == .vargvar or t.k == .nonreloc or t.k == .upval);
        if (t.k == .upval and !fs.isKstr(k)) _ = try fs.exp2anyreg(t);
        if (t.k == .upval) {
            t.ind.t = @intCast(t.info);
            t.ind.idx = k.info;
            t.k = .indexup;
        } else if (t.k == .vargvar) {
            const kreg = try fs.exp2anyreg(k);
            t.ind.t = t.ridx;
            t.ind.idx = kreg;
            t.k = .vargind;
        } else {
            t.ind.t = @intCast(if (t.k == .local) t.ridx else t.info);
            if (fs.isKstr(k)) {
                t.ind.idx = k.info;
                t.k = .indexstr;
            } else if (isCint(k)) {
                t.ind.idx = @intCast(k.ival);
                t.k = .indexi;
            } else {
                t.ind.idx = try fs.exp2anyreg(k);
                t.k = .indexed;
            }
        }
        t.ind.keystr = keystr;
        t.ind.ro = false;
    }

    fn codeUnExpVal(fs: *FuncState, o: OpCode, e: *ExpDesc, line: u32) Error!void {
        const r = try fs.exp2anyreg(e);
        fs.freeExp(e);
        e.info = try fs.codeAbc(o, 0, r, 0);
        e.k = .reloc;
        fs.fixLine(line);
    }

    fn finishBinExpVal(
        fs: *FuncState,
        e1: *ExpDesc,
        e2: *ExpDesc,
        o: OpCode,
        v2: i32,
        flip: bool,
        line: u32,
        mmop: OpCode,
        event: State.Tm,
    ) Error!void {
        const v1 = try fs.exp2anyreg(e1);
        const at = try fs.codeAbck(o, 0, v1, v2, false);
        fs.freeExps(e1, e2);
        e1.info = at;
        e1.k = .reloc;
        fs.fixLine(line);
        _ = try fs.codeAbck(mmop, v1, v2, @intFromEnum(event), flip);
        fs.fixLine(line);
    }

    fn codeBinExpVal(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
        const o = binopr2op(opr, .add, .add);
        const v2 = try fs.exp2anyreg(e2);
        try fs.finishBinExpVal(e1, e2, o, v2, false, line, .mmbin, binopr2tm(opr));
    }

    fn codeBinI(
        fs: *FuncState,
        o: OpCode,
        e1: *ExpDesc,
        e2: *ExpDesc,
        flip: bool,
        line: u32,
        event: State.Tm,
    ) Error!void {
        std.debug.assert(e2.k == .kint);
        const v2: i32 = opcodes.int2sc(@intCast(e2.ival));
        try fs.finishBinExpVal(e1, e2, o, v2, flip, line, .mmbini, event);
    }

    fn codeBinK(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32) Error!void {
        const event = binopr2tm(opr);
        const v2 = e2.info;
        const o = binopr2op(opr, .add, .addk);
        try fs.finishBinExpVal(e1, e2, o, v2, flip, line, .mmbink, event);
    }

    /// Codes the operation with the negated integer constant `e2` (as
    /// `r1 + -I` for `r1 - I`); the metamethod keeps the original operand.
    fn finishBinExpNeg(fs: *FuncState, e1: *ExpDesc, e2: *ExpDesc, o: OpCode, line: u32, event: State.Tm) Error!bool {
        if (!isKint(e2)) return false;
        const imm = e2.ival;
        if (!(fitsC(imm) and fitsC(-%imm))) return false;
        const v2: i32 = @intCast(imm);
        try fs.finishBinExpVal(e1, e2, o, opcodes.int2sc(-v2), false, line, .mmbini, event);
        setB(fs.inst(fs.pc() - 1), opcodes.int2sc(v2));
        return true;
    }

    fn codeBinNoK(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32) Error!void {
        if (flip) std.mem.swap(ExpDesc, e1, e2);
        try fs.codeBinExpVal(opr, e1, e2, line);
    }

    fn codeArith(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32) Error!void {
        if (toNumeral(e2, null) and try fs.exp2K(e2)) {
            try fs.codeBinK(opr, e1, e2, flip, line);
        } else {
            try fs.codeBinNoK(opr, e1, e2, flip, line);
        }
    }

    fn codeCommutative(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
        var flip = false;
        if (toNumeral(e1, null)) {
            std.mem.swap(ExpDesc, e1, e2);
            flip = true;
        }
        if (opr == .add and isSCint(e2)) {
            try fs.codeBinI(.addi, e1, e2, flip, line, .add);
        } else {
            try fs.codeArith(opr, e1, e2, flip, line);
        }
    }

    fn codeBitwise(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
        var flip = false;
        if (e1.k == .kint) {
            std.mem.swap(ExpDesc, e1, e2);
            flip = true;
        }
        if (e2.k == .kint and try fs.exp2K(e2)) {
            try fs.codeBinK(opr, e1, e2, flip, line);
        } else {
            try fs.codeBinNoK(opr, e1, e2, flip, line);
        }
    }

    fn codeOrder(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc) Error!void {
        var r1: i32 = undefined;
        var r2: i32 = undefined;
        var isfloat = false;
        var o: OpCode = undefined;
        if (isSCnumber(e2, &isfloat)) |im| {
            r1 = try fs.exp2anyreg(e1);
            r2 = im;
            o = binopr2op(opr, .lt, .lti);
        } else if (isSCnumber(e1, &isfloat)) |im| {
            r1 = try fs.exp2anyreg(e2);
            r2 = im;
            o = binopr2op(opr, .lt, .gti);
        } else {
            r1 = try fs.exp2anyreg(e1);
            r2 = try fs.exp2anyreg(e2);
            o = binopr2op(opr, .lt, .lt);
        }
        fs.freeExps(e1, e2);
        e1.info = try fs.condJump(o, r1, r2, @intFromBool(isfloat), true);
        e1.k = .jmp;
    }

    fn codeEq(fs: *FuncState, opr: BinOpr, e1: *ExpDesc, e2: *ExpDesc) Error!void {
        var r2: i32 = undefined;
        var isfloat = false;
        var o: OpCode = undefined;
        if (e1.k != .nonreloc) {
            std.debug.assert(e1.k == .k or e1.k == .kint or e1.k == .kflt);
            std.mem.swap(ExpDesc, e1, e2);
        }
        const r1 = try fs.exp2anyreg(e1);
        if (isSCnumber(e2, &isfloat)) |im| {
            o = .eqi;
            r2 = im;
        } else if (try fs.exp2Rk(e2)) {
            o = .eqk;
            r2 = e2.info;
        } else {
            o = .eq;
            r2 = try fs.exp2anyreg(e2);
        }
        fs.freeExps(e1, e2);
        e1.info = try fs.condJump(o, r1, r2, @intFromBool(isfloat), opr == .eq);
        e1.k = .jmp;
    }

    /// Applies prefix operator `opr` to `e`.
    pub fn prefix(fs: *FuncState, opr: UnOpr, e: *ExpDesc, line: u32) Error!void {
        const ef: ExpDesc = .{ .k = .kint, .ival = 0 };
        try fs.dischargeVars(e);
        switch (opr) {
            .minus, .bnot => {
                const o: FoldOp = if (opr == .minus) .unm else .bnot;
                if (constFolding(o, e, &ef)) return;
                try fs.codeUnExpVal(if (opr == .minus) .unm else .bnot, e, line);
            },
            .len => try fs.codeUnExpVal(.len, e, line),
            .not => try fs.codeNot(e),
            .none => unreachable,
        }
    }

    /// Processes the first operand of a binary operator before the second
    /// is read.
    pub fn infix(fs: *FuncState, opr: BinOpr, v: *ExpDesc) Error!void {
        try fs.dischargeVars(v);
        switch (opr) {
            .@"and" => try fs.goIfTrue(v),
            .@"or" => try fs.goIfFalse(v),
            .concat => try fs.exp2nextreg(v),
            .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
                // A numeral may fold or become an immediate operand.
                if (!toNumeral(v, null)) _ = try fs.exp2anyreg(v);
            },
            .eq, .ne => {
                if (!toNumeral(v, null)) _ = try fs.exp2Rk(v);
            },
            .lt, .le, .gt, .ge => {
                var dummy = false;
                if (isSCnumber(v, &dummy) == null) _ = try fs.exp2anyreg(v);
            },
            .none => unreachable,
        }
    }

    /// `e1 .. e2`, merging into the `CONCAT` of `e2` when it is one.
    fn codeConcat(fs: *FuncState, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
        if (fs.previousInstruction()) |ie2| {
            if (opcodes.op(ie2.*) == .concat) {
                const n: i32 = opcodes.b(ie2.*);
                std.debug.assert(e1.info + 1 == opcodes.a(ie2.*));
                fs.freeExp(e2);
                setA(ie2, e1.info);
                setB(ie2, n + 1);
                return;
            }
        }
        _ = try fs.codeAbc(.concat, e1.info, 2, 0);
        fs.freeExp(e2);
        fs.fixLine(line);
    }

    /// Finishes a binary operation once the second operand is read.
    pub fn posfix(fs: *FuncState, opr_: BinOpr, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
        var opr = opr_;
        try fs.dischargeVars(e2);
        if (opr.foldable() and constFolding(@enumFromInt(@intFromEnum(opr)), e1, e2)) return;
        switch (opr) {
            .@"and" => {
                std.debug.assert(e1.t == no_jump);
                try fs.concat(&e2.f, e1.f);
                e1.* = e2.*;
            },
            .@"or" => {
                std.debug.assert(e1.f == no_jump);
                try fs.concat(&e2.t, e1.t);
                e1.* = e2.*;
            },
            .concat => {
                try fs.exp2nextreg(e2);
                try fs.codeConcat(e1, e2, line);
            },
            .add, .mul => try fs.codeCommutative(opr, e1, e2, line),
            .sub, .div, .idiv, .mod, .pow => {
                if (opr == .sub and try fs.finishBinExpNeg(e1, e2, .addi, line, .sub)) return;
                try fs.codeArith(opr, e1, e2, false, line);
            },
            .band, .bor, .bxor => try fs.codeBitwise(opr, e1, e2, line),
            .shl => {
                if (isSCint(e1)) {
                    std.mem.swap(ExpDesc, e1, e2);
                    try fs.codeBinI(.shli, e1, e2, true, line, .shl);
                } else if (try fs.finishBinExpNeg(e1, e2, .shri, line, .shl)) {
                    // Coded as r1 >> -I.
                } else {
                    try fs.codeBinExpVal(opr, e1, e2, line);
                }
            },
            .shr => {
                if (isSCint(e2)) {
                    try fs.codeBinI(.shri, e1, e2, false, line, .shr);
                } else {
                    try fs.codeBinExpVal(opr, e1, e2, line);
                }
            },
            .eq, .ne => try fs.codeEq(opr, e1, e2),
            .gt, .ge, .lt, .le => {
                if (opr == .gt or opr == .ge) {
                    // a > b is b < a; a >= b is b <= a.
                    std.mem.swap(ExpDesc, e1, e2);
                    opr = if (opr == .gt) .lt else .le;
                }
                try fs.codeOrder(opr, e1, e2);
            },
            .none => unreachable,
        }
    }

    /// Sets the line of the last instruction.
    pub fn fixLine(fs: *FuncState, line: u32) void {
        fs.lines.items[fs.lines.items.len - 1] = line;
    }

    /// Fills in the `NEWTABLE` at `at` and its `EXTRAARG` with the sizes.
    pub fn setTableSize(fs: *FuncState, at: i32, ra: i32, asize: i32, hsize: i32) void {
        const extra = @divTrunc(asize, opcodes.max_vc + 1);
        const rc = @rem(asize, opcodes.max_vc + 1);
        const hs: i32 = if (hsize != 0) @as(i32, ceilLog2(@intCast(hsize))) + 1 else 0;
        fs.inst(at).* = opcodes.vabc(.newtable, @intCast(ra), @intCast(hs), @intCast(rc), extra > 0);
        fs.inst(at + 1).* = opcodes.iax(.extraarg, @intCast(extra));
    }

    /// Emits a `SETLIST` storing `tostore` values (or up to top, for
    /// `multret`) after the first `nelems - tostore` the table holds.
    pub fn setList(fs: *FuncState, base: i32, nelems_: i32, tostore_: i32) Error!void {
        var nelems = nelems_;
        std.debug.assert(tostore_ != 0);
        const tostore = if (tostore_ == multret) 0 else tostore_;
        if (nelems <= opcodes.max_vc) {
            _ = try fs.codevAbck(.setlist, base, tostore, nelems, false);
        } else {
            const extra = @divTrunc(nelems, opcodes.max_vc + 1);
            nelems = @rem(nelems, opcodes.max_vc + 1);
            _ = try fs.codevAbck(.setlist, base, tostore, nelems, true);
            _ = try fs.codeExtraArg(extra);
        }
        fs.freereg = base + 1;
    }

    /// The final peephole pass: returns and tail calls learn whether they
    /// close upvalues and how many hidden vararg slots to drop, vararg
    /// accesses move to the vararg table when there is one, and jumps to
    /// jumps go straight to the final target.
    pub fn finish(fs: *FuncState) Error!void {
        const p = fs.f;
        if (p.flags.vararg_table) p.flags.vararg = false;
        var i: i32 = 0;
        while (i < fs.pc()) : (i += 1) {
            const at = fs.inst(i);
            switch (opcodes.op(at.*)) {
                .return0, .return1, .@"return", .tailcall => {
                    const o = opcodes.op(at.*);
                    if (o == .return0 or o == .return1) {
                        if (!(fs.needclose or p.flags.vararg)) continue;
                        setOp(at, .@"return");
                    }
                    if (fs.needclose) setK(at, true);
                    if (p.flags.vararg) setC(at, @as(i32, p.numparams) + 1);
                },
                .getvarg => if (p.flags.vararg_table) setOp(at, .gettable),
                .vararg => if (p.flags.vararg_table) setK(at, true),
                .jmp => try fs.fixJump(i, finalTarget(fs.insts.items, i)),
                else => {},
            }
        }
    }
};

/// The operations constant folding knows, in `LUA_OPADD` order.
const FoldOp = enum(u8) { add, sub, mul, mod, pow, div, idiv, band, bor, bxor, shl, shr, unm, bnot };

fn toNumeral(e: *const ExpDesc, v: ?*Value) bool {
    if (e.hasJumps()) return false;
    switch (e.k) {
        .kint => if (v) |p| {
            p.* = .int(e.ival);
        },
        .kflt => if (v) |p| {
            p.* = .float(e.nval);
        },
        else => return false,
    }
    return true;
}

fn const2exp(v: Value, e: *ExpDesc) void {
    switch (v.tag) {
        .int => {
            e.k = .kint;
            e.ival = v.asInt();
        },
        .float => {
            e.k = .kflt;
            e.nval = v.asFloat();
        },
        .bool_false => e.k = .false,
        .bool_true => e.k = .true,
        .nil => e.k = .nil,
        .short_string, .long_string => {
            e.k = .kstr;
            e.strval = v.asString();
        },
        else => unreachable,
    }
}

fn isKint(e: *const ExpDesc) bool {
    return e.k == .kint and !e.hasJumps();
}

/// An integer constant that fits in a C operand.
fn isCint(e: *const ExpDesc) bool {
    return isKint(e) and @as(u64, @bitCast(e.ival)) <= opcodes.max_c;
}

/// An integer constant that fits in an sC operand.
fn isSCint(e: *const ExpDesc) bool {
    return isKint(e) and fitsC(e.ival);
}

/// The sB/sC field for an integer or integral float constant that fits,
/// or null; `isfloat` is set for a float.
fn isSCnumber(e: *const ExpDesc, isfloat: *bool) ?i32 {
    var i: i64 = undefined;
    if (e.k == .kint) {
        i = e.ival;
    } else if (e.k == .kflt) {
        i = number.floatToInt(e.nval, .exact) orelse return null;
        isfloat.* = true;
    } else return null;
    if (!e.hasJumps() and fitsC(i)) return opcodes.int2sc(@intCast(i));
    return null;
}

fn fitsC(i: i64) bool {
    return @as(u64, @bitCast(i)) +% opcodes.offset_sc <= opcodes.max_c;
}

fn fitsBx(i: i64) bool {
    return -opcodes.offset_sbx <= i and i <= opcodes.max_bx - opcodes.offset_sbx;
}

/// Whether folding `o` over these operands is safe: bitwise operands must
/// be integers and divisors nonzero.
fn validOp(o: FoldOp, v1: Value, v2: Value) bool {
    return switch (o) {
        .band, .bor, .bxor, .shl, .shr, .bnot => toIntExact(v1) != null and toIntExact(v2) != null,
        .div, .idiv, .mod => v2.asNumber() != 0,
        else => true,
    };
}

fn toIntExact(v: Value) ?i64 {
    return if (v.tag == .int) v.asInt() else number.floatToInt(v.asFloat(), .exact);
}

/// Folds `e1 o e2` into `e1` when both are numerals and the result is
/// neither NaN nor a float zero; `luaO_rawarith`.
fn constFolding(o: FoldOp, e1: *ExpDesc, e2: *const ExpDesc) bool {
    var v1: Value = undefined;
    var v2: Value = undefined;
    if (!toNumeral(e1, &v1) or !toNumeral(e2, &v2) or !validOp(o, v1, v2)) return false;
    switch (o) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            const x = toIntExact(v1).?;
            const y = toIntExact(v2).?;
            e1.k = .kint;
            e1.ival = switch (o) {
                .band => x & y,
                .bor => x | y,
                .bxor => x ^ y,
                .shl => number.shiftLeft(x, y),
                .shr => number.shiftRight(x, y),
                .bnot => ~x,
                else => unreachable,
            };
            return true;
        },
        .add, .sub, .mul, .mod, .idiv, .unm => if (v1.tag == .int and v2.tag == .int) {
            const x = v1.asInt();
            const y = v2.asInt();
            e1.k = .kint;
            e1.ival = switch (o) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
                .mod => number.modInt(x, y) catch unreachable,
                .idiv => number.divFloorInt(x, y) catch unreachable,
                .unm => 0 -% x,
                else => unreachable,
            };
            return true;
        },
        .div, .pow => {},
    }
    const x = v1.asNumber();
    const y = v2.asNumber();
    const n: f64 = switch (o) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .pow => if (y == 2) x * x else libm.pow(x, y),
        .idiv => number.divFloorFloat(x, y),
        .mod => number.modFloat(x, y),
        .unm => -x,
        else => unreachable,
    };
    if (std.math.isNan(n) or n == 0) return false;
    e1.k = .kflt;
    e1.nval = n;
    return true;
}

fn binopr2op(opr: BinOpr, baser: BinOpr, base: OpCode) OpCode {
    return @enumFromInt(@intFromEnum(opr) - @intFromEnum(baser) + @intFromEnum(base));
}

fn binopr2tm(opr: BinOpr) State.Tm {
    return @enumFromInt(@intFromEnum(opr) - @intFromEnum(BinOpr.add) + @intFromEnum(State.Tm.add));
}

/// ceil(log2(x)) for x >= 1, `luaO_ceillog2`.
fn ceilLog2(x: u32) u8 {
    if (x <= 1) return 0;
    return @intCast(32 - @clz(x - 1));
}

/// The final target of the jump at `i`, through chains of jumps.
fn finalTarget(insts: []const Instruction, i_: i32) i32 {
    var i = i_;
    for (0..100) |_| {
        const at = insts[@intCast(i)];
        if (opcodes.op(at) != .jmp) break;
        i += opcodes.sj(at) + 1;
    }
    return i;
}

// Instruction field setters.

fn setOp(i: *Instruction, o: OpCode) void {
    i.* = (i.* & ~@as(u32, 0x7f)) | @intFromEnum(o);
}

fn setA(i: *Instruction, v: i32) void {
    i.* = (i.* & ~(@as(u32, 0xff) << 7)) | (@as(u32, @intCast(v)) << 7);
}

fn setK(i: *Instruction, v: bool) void {
    i.* = (i.* & ~(@as(u32, 1) << 15)) | (@as(u32, @intFromBool(v)) << 15);
}

fn setB(i: *Instruction, v: i32) void {
    i.* = (i.* & ~(@as(u32, 0xff) << 16)) | (@as(u32, @intCast(v)) << 16);
}

fn setC(i: *Instruction, v: i32) void {
    i.* = (i.* & ~(@as(u32, 0xff) << 24)) | (@as(u32, @intCast(v)) << 24);
}

pub fn setBx(i: *Instruction, v: i32) void {
    i.* = (i.* & 0x7fff) | (@as(u32, @intCast(v)) << 15);
}

test "ceilLog2 matches luaO_ceillog2" {
    const cases = [_][2]u32{ .{ 1, 0 }, .{ 2, 1 }, .{ 3, 2 }, .{ 4, 2 }, .{ 5, 3 }, .{ 256, 8 }, .{ 257, 9 } };
    for (cases) |c| try std.testing.expectEqual(@as(u8, @intCast(c[1])), ceilLog2(c[0]));
}

// Listing.

const format = @import("lib/format.zig");

/// Writes `p` and its nested functions as `luac -l -l` lists them, with
/// every address printed as 0x0, so listings from the two compare as text
/// once luac's addresses are masked the same way (`just bytecode`).
pub fn writeListing(w: *std.Io.Writer, p: *const Proto) std.Io.Writer.Error!void {
    const src = if (p.source) |s| s.bytes() else "=?";
    const name = if (src.len > 0 and (src[0] == '@' or src[0] == '='))
        src[1..]
    else if (src.len > 0 and src[0] == 0x1b)
        "(bstring)"
    else
        "(string)";
    const n = p.code.len;
    try w.print("\n{s} <{s}:{d},{d}> ({d} instruction{s} at 0x0)\n", .{
        if (p.linedefined == 0) "main" else "function", name, p.linedefined, p.lastlinedefined, n, plural(n),
    });
    const vararg = p.flags.vararg or p.flags.vararg_table;
    try w.print("{d}{s} param{s}, {d} slot{s}, {d} upvalue{s}, ", .{
        p.numparams,            if (vararg) "+" else "", plural(p.numparams),    p.maxstacksize,
        plural(p.maxstacksize), p.upvalues.len,          plural(p.upvalues.len),
    });
    try w.print("{d} local{s}, {d} constant{s}, {d} function{s}\n", .{
        p.locvars.len, plural(p.locvars.len), p.k.len, plural(p.k.len), p.p.len, plural(p.p.len),
    });
    for (p.code, 0..) |i, pc| try writeInstruction(w, p, i, pc);
    try w.print("constants ({d}) for 0x0:\n", .{p.k.len});
    for (p.k, 0..) |v, i| {
        const t: []const u8 = switch (v.tag) {
            .nil => "N",
            .bool_false, .bool_true => "B",
            .float => "F",
            .int => "I",
            else => "S",
        };
        try w.print("\t{d}\t{s}\t", .{ i, t });
        try writeConstant(w, v);
        try w.writeByte('\n');
    }
    try w.print("locals ({d}) for 0x0:\n", .{p.locvars.len});
    for (p.locvars, 0..) |l, i| {
        try w.print("\t{d}\t{s}\t{d}\t{d}\n", .{ i, if (l.name) |s| s.bytes() else "", l.startpc + 1, l.endpc + 1 });
    }
    try w.print("upvalues ({d}) for 0x0:\n", .{p.upvalues.len});
    for (p.upvalues, 0..) |u, i| {
        try w.print("\t{d}\t{s}\t{d}\t{d}\n", .{ i, upvalName(p, i), @intFromBool(u.instack), u.idx });
    }
    for (p.p) |child| try writeListing(w, child);
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn upvalName(p: *const Proto, i: usize) []const u8 {
    return if (p.upvalues[i].name) |s| s.bytes() else "-";
}

fn writeConstant(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v.tag) {
        .nil => try w.writeAll("nil"),
        .bool_false => try w.writeAll("false"),
        .bool_true => try w.writeAll("true"),
        .float => {
            var buf: [64]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            try format.formatFloat(&fw, .{ .conversion = 'g', .precision = 15 }, v.asFloat());
            const s = fw.buffered();
            try w.writeAll(s);
            if (std.mem.findNone(u8, s, "-0123456789") == null) try w.writeAll(".0");
        },
        .int => try w.print("{d}", .{v.asInt()}),
        else => {
            try w.writeByte('"');
            for (v.asString().bytes()) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                0x07 => try w.writeAll("\\a"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x0b => try w.writeAll("\\v"),
                else => if (c >= 0x20 and c < 0x7f) try w.writeByte(c) else try w.print("\\{d:0>3}", .{c}),
            };
            try w.writeByte('"');
        },
    }
}

/// luac's names for the opcodes, `opnames`.
fn opName(o: OpCode) []const u8 {
    return switch (o) {
        inline else => |t| comptime blk: {
            @setEvalBranchQuota(10_000);
            const tag = @tagName(t);
            var up: [tag.len]u8 = undefined;
            for (tag, 0..) |c, j| up[j] = std.ascii.toUpper(c);
            const final = up;
            break :blk &final;
        },
    };
}

fn writeInstruction(w: *std.Io.Writer, p: *const Proto, i: Instruction, pc: usize) std.Io.Writer.Error!void {
    const o = opcodes.op(i);
    const a = opcodes.a(i);
    const b = opcodes.b(i);
    const c = opcodes.c(i);
    const bx = opcodes.bx(i);
    const sb = opcodes.sb(i);
    const sc = opcodes.sc(i);
    const vb = opcodes.vb(i);
    const vc = opcodes.vc(i);
    const sbx = opcodes.sbx(i);
    const isk = opcodes.k(i);
    const ks: []const u8 = if (isk) "k" else "";
    const kn: u8 = @intFromBool(isk);
    try w.print("\t{d}\t", .{pc + 1});
    if (p.lineAt(pc)) |line| try w.print("[{d}]\t", .{line}) else try w.writeAll("[-]\t");
    const name = opName(o);
    try w.print("{s}", .{name});
    if (name.len < 9) try w.splatByteAll(' ', 9 - name.len);
    try w.writeByte('\t');
    const comment = "\t; ";
    const extra: u32 = if (pc + 1 < p.code.len) opcodes.ax(p.code[pc + 1]) else 0;
    switch (o) {
        .move, .unm, .bnot, .not, .len, .concat => try w.print("{d} {d}", .{ a, b }),
        .loadi, .loadf => try w.print("{d} {d}", .{ a, sbx }),
        .loadk => {
            try w.print("{d} {d}" ++ comment, .{ a, bx });
            try writeConstant(w, p.k[bx]);
        },
        .loadkx => {
            try w.print("{d}" ++ comment, .{a});
            try writeConstant(w, p.k[extra]);
        },
        .loadfalse, .lfalseskip, .loadtrue, .close, .tbc, .return1, .varargprep => try w.print("{d}", .{a}),
        .loadnil => try w.print("{d} {d}" ++ comment ++ "{d} out", .{ a, b, b + 1 }),
        .getupval, .setupval => try w.print("{d} {d}" ++ comment ++ "{s}", .{ a, b, upvalName(p, b) }),
        .gettabup => {
            try w.print("{d} {d} {d}" ++ comment ++ "{s} ", .{ a, b, c, upvalName(p, b) });
            try writeConstant(w, p.k[c]);
        },
        .gettable, .geti, .getvarg => try w.print("{d} {d} {d}", .{ a, b, c }),
        .add, .sub, .mul, .mod, .pow, .div, .idiv => try w.print("{d} {d} {d}", .{ a, b, c }),
        .band, .bor, .bxor, .shl, .shr => try w.print("{d} {d} {d}", .{ a, b, c }),
        .getfield, .addk, .subk, .mulk, .modk, .powk, .divk, .idivk, .bandk, .bork, .bxork => {
            try w.print("{d} {d} {d}" ++ comment, .{ a, b, c });
            try writeConstant(w, p.k[c]);
        },
        .settabup => {
            try w.print("{d} {d} {d}{s}" ++ comment ++ "{s} ", .{ a, b, c, ks, upvalName(p, a) });
            try writeConstant(w, p.k[b]);
            if (isk) {
                try w.writeByte(' ');
                try writeConstant(w, p.k[c]);
            }
        },
        .settable, .seti, .self => {
            try w.print("{d} {d} {d}{s}", .{ a, b, c, ks });
            if (isk) {
                try w.writeAll(comment);
                try writeConstant(w, p.k[c]);
            }
        },
        .setfield => {
            try w.print("{d} {d} {d}{s}" ++ comment, .{ a, b, c, ks });
            try writeConstant(w, p.k[b]);
            if (isk) {
                try w.writeByte(' ');
                try writeConstant(w, p.k[c]);
            }
        },
        .newtable => {
            const size = vc + extra * (opcodes.max_c + 1);
            try w.print("{d} {d} {d}{s}" ++ comment ++ "{d}", .{ a, vb, vc, ks, size });
        },
        .addi, .shli, .shri => try w.print("{d} {d} {d}", .{ a, b, sc }),
        .mmbin => try w.print("{d} {d} {d}" ++ comment ++ "{s}", .{ a, b, c, tmName(c) }),
        .mmbini => {
            try w.print("{d} {d} {d} {d}" ++ comment ++ "{s}", .{ a, sb, c, kn, tmName(c) });
            if (isk) try w.writeAll(" flip");
        },
        .mmbink => {
            try w.print("{d} {d} {d} {d}" ++ comment ++ "{s} ", .{ a, b, c, kn, tmName(c) });
            try writeConstant(w, p.k[b]);
            if (isk) try w.writeAll(" flip");
        },
        .jmp => {
            const sj = opcodes.sj(i);
            try w.print("{d}" ++ comment ++ "to {d}", .{ sj, sj + @as(i64, @intCast(pc)) + 2 });
        },
        .eq, .lt, .le => try w.print("{d} {d} {d}", .{ a, b, kn }),
        .eqk => {
            try w.print("{d} {d} {d}" ++ comment, .{ a, b, kn });
            try writeConstant(w, p.k[b]);
        },
        .eqi, .lti, .lei, .gti, .gei => try w.print("{d} {d} {d}", .{ a, sb, kn }),
        .@"test" => try w.print("{d} {d}", .{ a, kn }),
        .testset => try w.print("{d} {d} {d}", .{ a, b, kn }),
        .call => {
            try w.print("{d} {d} {d}" ++ comment, .{ a, b, c });
            if (b == 0) try w.writeAll("all in ") else try w.print("{d} in ", .{b - 1});
            if (c == 0) try w.writeAll("all out") else try w.print("{d} out", .{c - 1});
        },
        .tailcall => try w.print("{d} {d} {d}{s}" ++ comment ++ "{d} in", .{ a, b, c, ks, @as(i32, b) - 1 }),
        .@"return" => {
            try w.print("{d} {d} {d}{s}" ++ comment, .{ a, b, c, ks });
            if (b == 0) try w.writeAll("all out") else try w.print("{d} out", .{b - 1});
        },
        .return0 => {},
        .forloop, .tforloop => {
            const to = @as(i64, @intCast(pc)) - bx + 2;
            try w.print("{d} {d}" ++ comment ++ "to {d}", .{ a, bx, to });
        },
        .forprep => try w.print("{d} {d}" ++ comment ++ "exit to {d}", .{ a, bx, pc + bx + 3 }),
        .tforprep => try w.print("{d} {d}" ++ comment ++ "to {d}", .{ a, bx, pc + bx + 2 }),
        .tforcall => try w.print("{d} {d}", .{ a, c }),
        .setlist => {
            try w.print("{d} {d} {d}{s}", .{ a, vb, vc, ks });
            if (isk) try w.print(comment ++ "{d}", .{c + extra * (opcodes.max_c + 1)});
        },
        .closure => try w.print("{d} {d}" ++ comment ++ "0x0", .{ a, bx }),
        .vararg => {
            try w.print("{d} {d} {d}{s}" ++ comment, .{ a, b, c, ks });
            if (c == 0) try w.writeAll("all out") else try w.print("{d} out", .{c - 1});
        },
        .errnnil => {
            try w.print("{d} {d}" ++ comment, .{ a, bx });
            if (bx == 0) try w.writeAll("?") else try writeConstant(w, p.k[bx - 1]);
        },
        .extraarg => try w.print("{d}", .{opcodes.ax(i)}),
    }
    try w.writeByte('\n');
}

fn tmName(c: u8) []const u8 {
    if (c >= State.Tm.count) return "?";
    return @as(State.Tm, @enumFromInt(c)).name();
}
