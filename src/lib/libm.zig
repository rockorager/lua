//! `exp`, `pow`, `log`, `log2`, and `log10` computed the way the
//! reference's C library computes them, so results match it bit for bit:
//! glibc's double-precision code (sysdeps/ieee754/dbl-64; all but `log10`
//! from Arm's optimized-routines), with glibc's tables. Zig's `std.math`
//! rounds `exp` and `pow` differently in about 7% and 54% of random
//! arguments, and `log2` and `log10` in a fraction of a percent.
//!
//! glibc picks a variant built with `-mfma` on CPUs that have FMA, and GCC
//! contracts `a * b + c` into fused multiply-adds there. `mad` does the same
//! when the target has FMA, so a native build matches the reference on the
//! same machine; a build for a CPU without FMA follows glibc's generic code.

const std = @import("std");
const builtin = @import("builtin");

const has_fma = switch (builtin.cpu.arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    .aarch64 => true,
    else => false,
};

/// `a * b + c` as GCC compiles it for glibc: fused when the target has FMA.
inline fn mad(a: f64, b: f64, c: f64) f64 {
    return if (has_fma) @mulAdd(f64, a, b, c) else a * b + c;
}

inline fn asU64(x: f64) u64 {
    return @bitCast(x);
}

inline fn asF64(x: u64) f64 {
    return @bitCast(x);
}

inline fn top12(x: f64) u32 {
    return @intCast(asU64(x) >> 52);
}

/// `__math_oflow`, `__math_uflow`, and `__math_invalid`: the results the
/// arithmetic that raises the exception gives.
fn overflow(negative: bool) f64 {
    const y: f64 = if (negative) -0x1p769 else 0x1p769;
    return y * 0x1p769;
}

fn underflow(negative: bool) f64 {
    const y: f64 = if (negative) -0x1p-767 else 0x1p-767;
    return y * 0x1p-767;
}

fn invalid(x: f64) f64 {
    var d = x - x;
    // Keep the division at run time, where x86 gives its negative NaN.
    std.mem.doNotOptimizeAway(&d);
    return d / d;
}

// The exp tables (`__exp_data`, EXP_TABLE_BITS 7, EXP_POLY_ORDER 5).
const exp_bits = 7;
const exp_n = 1 << exp_bits;
const inv_ln2_n = 0x1.71547652b82fep0 * exp_n;
const neg_ln2_hi_n = -0x1.62e42fefa0000p-8;
const neg_ln2_lo_n = -0x1.cf79abc9e3b3ap-47;
const shift = 0x1.8p52;
const c2 = 0x1.ffffffffffdbdp-2;
const c3 = 0x1.555555555543cp-3;
const c4 = 0x1.55555cf172b91p-5;
const c5 = 0x1.1111167a4d017p-7;

/// e^x.
pub fn exp(x: f64) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) - top12(0x1p-54)) {
        // Tiny x, including 0.
        if (abstop -% top12(0x1p-54) >= 0x80000000) return 1.0 + x;
        if (abstop >= top12(1024.0)) {
            if (asU64(x) == asU64(-std.math.inf(f64))) return 0.0;
            if (abstop >= top12(std.math.inf(f64))) return 1.0 + x;
            return if (asU64(x) >> 63 != 0) underflow(false) else overflow(false);
        }
        // Large x is handled by `specialCase`.
        abstop = 0;
    }
    // exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)];
    // x = ln2/N*k + r, with integer k and r in [-ln2/2N, ln2/2N].
    var kd = mad(inv_ln2_n, x, shift);
    const ki = asU64(kd);
    kd -= shift;
    const r = mad(kd, neg_ln2_lo_n, mad(kd, neg_ln2_hi_n, x));
    // 2^(k/N) ~= scale * (1 + tail).
    const idx = 2 * (ki % exp_n);
    const top = ki << (52 - exp_bits);
    const tail = asF64(exp_tab[idx]);
    // This is only a valid scale when -1023*N < k < 1024*N.
    const sbits = exp_tab[idx + 1] +% top;
    // exp(x) ~= scale + scale * (tail + exp(r) - 1).
    const r2 = r * r;
    const tmp = mad(r2 * r2, mad(r, c5, c4), mad(r2, mad(r, c3, c2), tail + r));
    if (abstop == 0) return expSpecial(tmp, sbits, ki);
    const scale = asF64(sbits);
    return mad(scale, tmp, scale);
}

/// `specialcase` of e_exp.c: results that may overflow or underflow.
fn expSpecial(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if (ki & 0x80000000 == 0) {
        // k > 0: the exponent of scale might have overflowed by <= 460.
        sbits -%= 1009 << 52;
        const scale = asF64(sbits);
        return 0x1p1009 * mad(scale, tmp, scale);
    }
    // k < 0: care is needed in the subnormal range.
    sbits +%= 1022 << 52;
    const scale = asF64(sbits);
    var y = mad(scale, tmp, scale);
    if (y < 1.0) {
        // Round y to the right precision before scaling it into the
        // subnormal range, avoiding double rounding.
        var lo = mad(scale, tmp, scale - y);
        const hi = 1.0 + y;
        lo = 1.0 - hi + y + lo;
        y = (hi + lo) - 1.0;
        if (y == 0.0) y = 0.0;
    }
    return 0x1p-1022 * y;
}

/// `specialcase` of e_pow.c, which also handles a negative result.
fn powSpecial(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if (ki & 0x80000000 == 0) {
        sbits -%= 1009 << 52;
        const scale = asF64(sbits);
        const y = mad(scale, tmp, scale);
        // Without FMA, glibc checks for a rounding mode that is not to
        // nearest here; in that mode the result is to nearest anyway.
        return y * 0x1p1009;
    }
    sbits +%= 1022 << 52;
    const scale = asF64(sbits);
    var y = mad(scale, tmp, scale);
    if (@abs(y) < 1.0) {
        const one: f64 = if (y < 0.0) -1.0 else 1.0;
        var lo = mad(scale, tmp, scale - y);
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (hi + lo) - one;
        if (y == 0.0) y = asF64(sbits & 0x8000000000000000);
    }
    return 0x1p-1022 * y;
}

const sign_bias_neg: u64 = 0x800 << exp_bits;

// The pow log tables (`__pow_log_data`, POW_LOG_TABLE_BITS 7,
// POW_LOG_POLY_ORDER 8).
const log_bits = 7;
const log_n = 1 << log_bits;
const log_off: u64 = 0x3fe6955500000000;
const ln2_hi = 0x1.62e42fefa3800p-1;
const ln2_lo = 0x1.ef35793c76730p-45;
const a0 = -0x1p-1;
const a1 = 0x1.555555555556p-2 * -2.0;
const a2 = -0x1.0000000000006p-2 * -2.0;
const a3 = 0x1.999999959554ep-3 * 4.0;
const a4 = -0x1.555555529a47ap-3 * 4.0;
const a5 = 0x1.2495b9b4845e9p-3 * -8.0;
const a6 = -0x1.0002b8b263fc3p-3 * -8.0;

/// log(x) as y + tail, where tail carries about 15 more bits; `ix` is x's
/// representation, normalized in the subnormal range (`log_inline`).
inline fn logInline(ix: u64, tail: *f64) f64 {
    // x = 2^k z, with z in [OFF, 2*OFF) and exact.
    const tmp = ix -% log_off;
    const i: usize = @intCast((tmp >> (52 - log_bits)) % log_n);
    const k = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z = asF64(iz);
    const kd: f64 = @floatFromInt(k);
    const e = pow_log_tab[i];
    // 1/c is j/N or j/N/2, so r = z/c - 1 is exact.
    var r: f64 = undefined;
    var rhi: f64 = undefined;
    var rlo: f64 = undefined;
    if (has_fma) {
        r = @mulAdd(f64, z, e.invc, -1.0);
    } else {
        const zhi = asF64((iz +% (1 << 31)) & (~@as(u64, 0) << 32));
        const zlo = z - zhi;
        rhi = zhi * e.invc - 1.0;
        rlo = zlo * e.invc;
        r = rhi + rlo;
    }
    // k*Ln2 + log(c) + r.
    const t1 = mad(kd, ln2_hi, e.logc);
    const t2 = t1 + r;
    const lo1 = mad(kd, ln2_lo, e.logctail);
    const lo2 = t1 - t2 + r;
    // Evaluation is optimized assuming superscalar pipelined execution.
    const ar = a0 * r;
    const ar2 = r * ar;
    const ar3 = r * ar2;
    var hi: f64 = undefined;
    var lo3: f64 = undefined;
    var lo4: f64 = undefined;
    if (has_fma) {
        hi = t2 + ar2;
        lo3 = @mulAdd(f64, ar, r, -ar2);
        lo4 = t2 - hi + ar2;
    } else {
        const arhi = a0 * rhi;
        const arhi2 = rhi * arhi;
        hi = t2 + arhi2;
        lo3 = rlo * (ar + arhi);
        lo4 = t2 - hi + arhi2;
    }
    const q = mad(ar2, mad(ar2, mad(r, a6, a5), mad(r, a4, a3)), mad(r, a2, a1));
    const lo = mad(ar3, q, lo1 + lo2 + lo3 + lo4);
    const y = hi + lo;
    tail.* = hi - y + lo;
    return y;
}

/// 0 if `iy` (a nonzero finite double's bits) is not an integer, 1 if odd,
/// 2 if even.
fn checkInt(iy: u64) u2 {
    const e: u32 = @intCast(iy >> 52 & 0x7ff);
    if (e < 0x3ff) return 0;
    if (e > 0x3ff + 52) return 2;
    const bit = @as(u64, 1) << @intCast(0x3ff + 52 - e);
    if (iy & (bit - 1) != 0) return 0;
    if (iy & bit != 0) return 1;
    return 2;
}

/// Zero, infinity, or NaN.
inline fn zeroInfNan(i: u64) bool {
    return 2 *% i -% 1 >= 2 *% asU64(std.math.inf(f64)) -% 1;
}

inline fn isSignaling(x: f64) bool {
    const i = asU64(x);
    return (i & 0x7ff8000000000000) == 0x7ff0000000000000 and (i & 0x000fffffffffffff) != 0;
}

/// x^y.
pub fn pow(x: f64, y: f64) f64 {
    var sign_bias: u64 = 0;
    var ix = asU64(x);
    const iy = asU64(y);
    var topx = top12(x);
    const topy = top12(y);
    const inf = asU64(std.math.inf(f64));
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        // x < 0x1p-126, inf, or nan; or |y| < 0x1p-65, |y| >= 0x1p63, or nan.
        if (zeroInfNan(iy)) {
            if (2 *% iy == 0) return if (isSignaling(x)) x + y else 1.0;
            if (ix == asU64(1.0)) return if (isSignaling(y)) x + y else 1.0;
            if (2 *% ix > 2 *% inf or 2 *% iy > 2 *% inf) return x + y;
            if (2 *% ix == 2 *% asU64(1.0)) return 1.0;
            // |x| < 1 and y == inf, or |x| > 1 and y == -inf.
            if ((2 *% ix < 2 *% asU64(1.0)) == (iy >> 63 == 0)) return 0.0;
            return y * y;
        }
        if (zeroInfNan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkInt(iy) == 1) x2 = -x2;
            return if (iy >> 63 != 0) 1 / x2 else x2;
        }
        if (ix >> 63 != 0) {
            // Finite x < 0.
            const yint = checkInt(iy);
            if (yint == 0) return invalid(x);
            if (yint == 1) sign_bias = sign_bias_neg;
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            // sign_bias is 0 here because y is not odd.
            if (ix == asU64(1.0)) return 1.0;
            // |y| < 2^-65: x^y ~= 1 + y*log(x).
            if ((topy & 0x7ff) < 0x3be) return if (ix > asU64(1.0)) 1.0 + y else 1.0 - y;
            return if ((ix > asU64(1.0)) == (topy < 0x800)) overflow(false) else underflow(false);
        }
        if (topx == 0) {
            // Normalize a subnormal x so its exponent becomes negative.
            ix = asU64(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix -%= 52 << 52;
        }
    }
    var lo: f64 = undefined;
    const hi = logInline(ix, &lo);
    var ehi: f64 = undefined;
    var elo: f64 = undefined;
    if (has_fma) {
        ehi = y * hi;
        elo = @mulAdd(f64, y, lo, @mulAdd(f64, y, hi, -ehi));
    } else {
        const yhi = asF64(iy & (~@as(u64, 0) << 27));
        const ylo = y - yhi;
        const lhi = asF64(asU64(hi) & (~@as(u64, 0) << 27));
        const llo = hi - lhi + lo;
        ehi = yhi * lhi;
        elo = ylo * lhi + y * llo;
    }
    return expInline(ehi, elo, sign_bias);
}

/// `exp_inline` of e_pow.c: sign * e^(x + xtail).
fn expInline(x: f64, xtail: f64, sign_bias: u64) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) - top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            // Tiny x.
            const one = 1.0 + x;
            return if (sign_bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            // inf and nan are already handled.
            return if (asU64(x) >> 63 != 0) underflow(sign_bias != 0) else overflow(sign_bias != 0);
        }
        abstop = 0;
    }
    var kd = mad(inv_ln2_n, x, shift);
    const ki = asU64(kd);
    kd -= shift;
    var r = mad(kd, neg_ln2_lo_n, mad(kd, neg_ln2_hi_n, x));
    r += xtail;
    const idx = 2 * (ki % exp_n);
    const top = (ki +% sign_bias) << (52 - exp_bits);
    const tail = asF64(exp_tab[idx]);
    const sbits = exp_tab[idx + 1] +% top;
    const r2 = r * r;
    const tmp = mad(r2 * r2, mad(r, c5, c4), mad(r2, mad(r, c3, c2), tail + r));
    if (abstop == 0) return powSpecial(tmp, sbits, ki);
    const scale = asF64(sbits);
    return mad(scale, tmp, scale);
}

/// 2^(k/N) ~= H[k]*(1 + T[k]) for k in [0, N): `exp_tab[2k]` is T[k]'s
/// bits, `exp_tab[2k+1]` is H[k]'s bits minus (k << 52)/N.
const exp_tab = [2 * exp_n]u64{
    0x0000000000000000, 0x3ff0000000000000,
    0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
    0xbc7160139cd8dc5d, 0x3fefec9a3e778061,
    0xbc905e7a108766d1, 0x3fefe315e86e7f85,
    0x3c8cd2523567f613, 0x3fefd9b0d3158574,
    0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
    0x3c60f74e61e6c861, 0x3fefc74518759bc8,
    0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
    0x3c979aa65d837b6d, 0x3fefb5586cf9890f,
    0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
    0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2,
    0xbc6a033489906e0b, 0x3fef9b66affed31b,
    0xbc9556522a2fbd0e, 0x3fef9301d0125b51,
    0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
    0xbc91c923b9d5f416, 0x3fef829aaea92de0,
    0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
    0xbc801b15eaa59348, 0x3fef72b83c7d517b,
    0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
    0x3c8b898c3f1353bf, 0x3fef635beb6fcb75,
    0xbc96d99c7611eb26, 0x3fef5be084045cd4,
    0x3c9aecf73e3a2f60, 0x3fef54873168b9aa,
    0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
    0x3c8a6f4144a6c38d, 0x3fef463b88628cd6,
    0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
    0x3c968efde3a8a894, 0x3fef387a6e756238,
    0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
    0x3c80472b981fe7f2, 0x3fef2b4565e27cdd,
    0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
    0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1,
    0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
    0x3c8b3782720c0ab4, 0x3fef1285a6e4030b,
    0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
    0x3c834d754db0abb6, 0x3fef06fe0a31b715,
    0x3c864201e2ac744c, 0x3fef0170fc4cd831,
    0x3c8fdd395dd3f84a, 0x3feefc08b26416ff,
    0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
    0xbc924aedcc4b5068, 0x3feef1a7373aa9cb,
    0xbc9907f81b512d8e, 0x3feeecae6d05d866,
    0xbc71d1e83e9436d2, 0x3feee7db34e59ff7,
    0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
    0x3c859f48a72a4c6d, 0x3feedea64c123422,
    0xbc9312607a28698a, 0x3feeda4504ac801c,
    0xbc58a78f4817895b, 0x3feed60a21f72e2a,
    0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
    0x3c4363ed60c2ac11, 0x3feece086061892d,
    0x3c9666093b0664ef, 0x3feeca41ed1d0057,
    0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0,
    0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
    0x3c7690cebb7aafb0, 0x3feebfdad5362a27,
    0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
    0xbc8f94340071a38e, 0x3feeb9b2769d2ca7,
    0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
    0xbc78dec6bd0f385f, 0x3feeb42b569d4f82,
    0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
    0x3c93350518fdd78e, 0x3feeaf4736b527da,
    0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
    0x3c9063e1e21c5409, 0x3feeab07dd485429,
    0x3c34c7855019c6ea, 0x3feea9268a5946b7,
    0x3c9432e62b64c035, 0x3feea76f15ad2148,
    0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
    0xbc8c33c53bef4da8, 0x3feea47eb03a5585,
    0xbc845378892be9ae, 0x3feea34634ccc320,
    0xbc93cedd78565858, 0x3feea23882552225,
    0x3c5710aa807e1964, 0x3feea155d44ca973,
    0xbc93b3efbf5e2228, 0x3feea09e667f3bcd,
    0xbc6a12ad8734b982, 0x3feea012750bdabf,
    0xbc6367efb86da9ee, 0x3fee9fb23c651a2f,
    0xbc80dc3d54e08851, 0x3fee9f7df9519484,
    0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74,
    0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
    0xbc8619321e55e68a, 0x3fee9feb564267c9,
    0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
    0xbc7b32dcb94da51d, 0x3feea11473eb0187,
    0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
    0x3c65ebe1abd66c55, 0x3feea2f336cf4e62,
    0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
    0xbc9369b6f13b3734, 0x3feea589994cce13,
    0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
    0xbc94d450d872576e, 0x3feea8d99b4492ed,
    0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
    0x3c8db72fc1f0eab4, 0x3feeace5422aa0db,
    0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
    0x3c7bf68359f35f44, 0x3feeb1ae99157736,
    0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
    0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5,
    0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
    0xbc92434322f4f9aa, 0x3feebd829fde4e50,
    0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
    0x3c71affc2b91ce27, 0x3feec49182a3f090,
    0x3c6dd235e10a73bb, 0x3feec86319e32323,
    0xbc87c50422622263, 0x3feecc667b5de565,
    0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
    0xbc91bbd1d3bcbb15, 0x3feed503b23e255d,
    0x3c90cc319cee31d2, 0x3feed99e1330b358,
    0x3c8469846e735ab3, 0x3feede6b5579fdbf,
    0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
    0x3c8c1a7792cb3387, 0x3feee89f995ad3ad,
    0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
    0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb,
    0xbc90a40e3da6f640, 0x3feef9728de5593a,
    0xbc68d6f438ad9334, 0x3feeff76f2fb5e47,
    0xbc91eee26b588a35, 0x3fef05b030a1064a,
    0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2,
    0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
    0x3c736eae30af0cb3, 0x3fef199bdd85529c,
    0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
    0x3c84e08fd10959ac, 0x3fef27f12e57d14b,
    0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
    0x3c676b2c6c921968, 0x3fef3720dcef9069,
    0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
    0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c,
    0xbc900dae3875a949, 0x3fef4f87080d89f2,
    0x3c74a385a63d07a7, 0x3fef5818dcfba487,
    0xbc82919e2040220f, 0x3fef60e316c98398,
    0x3c8e5a50d5c192ac, 0x3fef69e603db3285,
    0x3c843a59ac016b4b, 0x3fef7321f301b460,
    0xbc82d52107b43e1f, 0x3fef7c97337b9b5f,
    0xbc892ab93b470dc9, 0x3fef864614f5a129,
    0x3c74b604603a88d3, 0x3fef902ee78b3ff6,
    0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
    0xbc8ff7128fd391f0, 0x3fefa4afa2a490da,
    0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
    0x3c8ec3bc41aa2008, 0x3fefba1bee615a27,
    0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
    0x3c8a64a931d185ee, 0x3fefd0765b6e4540,
    0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
    0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8,
    0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
};

const PowLogEntry = struct { invc: f64, logc: f64, logctail: f64 };

/// 1/c, log(c) rounded to 43 bits, and the rest of log(c), for c near the
/// center of each of the N subintervals of [0x1.69555p-1, 0x1.69555p0].
const pow_log_tab = [log_n]PowLogEntry{
    .{ .invc = 0x1.6a00000000000p+0, .logc = -0x1.62c82f2b9c800p-2, .logctail = 0x1.ab42428375680p-48 },
    .{ .invc = 0x1.6800000000000p+0, .logc = -0x1.5d1bdbf580800p-2, .logctail = -0x1.ca508d8e0f720p-46 },
    .{ .invc = 0x1.6600000000000p+0, .logc = -0x1.5767717455800p-2, .logctail = -0x1.362a4d5b6506dp-45 },
    .{ .invc = 0x1.6400000000000p+0, .logc = -0x1.51aad872df800p-2, .logctail = -0x1.684e49eb067d5p-49 },
    .{ .invc = 0x1.6200000000000p+0, .logc = -0x1.4be5f95777800p-2, .logctail = -0x1.41b6993293ee0p-47 },
    .{ .invc = 0x1.6000000000000p+0, .logc = -0x1.4618bc21c6000p-2, .logctail = 0x1.3d82f484c84ccp-46 },
    .{ .invc = 0x1.5e00000000000p+0, .logc = -0x1.404308686a800p-2, .logctail = 0x1.c42f3ed820b3ap-50 },
    .{ .invc = 0x1.5c00000000000p+0, .logc = -0x1.3a64c55694800p-2, .logctail = 0x1.0b1c686519460p-45 },
    .{ .invc = 0x1.5a00000000000p+0, .logc = -0x1.347dd9a988000p-2, .logctail = 0x1.5594dd4c58092p-45 },
    .{ .invc = 0x1.5800000000000p+0, .logc = -0x1.2e8e2bae12000p-2, .logctail = 0x1.67b1e99b72bd8p-45 },
    .{ .invc = 0x1.5600000000000p+0, .logc = -0x1.2895a13de8800p-2, .logctail = 0x1.5ca14b6cfb03fp-46 },
    .{ .invc = 0x1.5600000000000p+0, .logc = -0x1.2895a13de8800p-2, .logctail = 0x1.5ca14b6cfb03fp-46 },
    .{ .invc = 0x1.5400000000000p+0, .logc = -0x1.22941fbcf7800p-2, .logctail = -0x1.65a242853da76p-46 },
    .{ .invc = 0x1.5200000000000p+0, .logc = -0x1.1c898c1699800p-2, .logctail = -0x1.fafbc68e75404p-46 },
    .{ .invc = 0x1.5000000000000p+0, .logc = -0x1.1675cababa800p-2, .logctail = 0x1.f1fc63382a8f0p-46 },
    .{ .invc = 0x1.4e00000000000p+0, .logc = -0x1.1058bf9ae4800p-2, .logctail = -0x1.6a8c4fd055a66p-45 },
    .{ .invc = 0x1.4c00000000000p+0, .logc = -0x1.0a324e2739000p-2, .logctail = -0x1.c6bee7ef4030ep-47 },
    .{ .invc = 0x1.4a00000000000p+0, .logc = -0x1.0402594b4d000p-2, .logctail = -0x1.036b89ef42d7fp-48 },
    .{ .invc = 0x1.4a00000000000p+0, .logc = -0x1.0402594b4d000p-2, .logctail = -0x1.036b89ef42d7fp-48 },
    .{ .invc = 0x1.4800000000000p+0, .logc = -0x1.fb9186d5e4000p-3, .logctail = 0x1.d572aab993c87p-47 },
    .{ .invc = 0x1.4600000000000p+0, .logc = -0x1.ef0adcbdc6000p-3, .logctail = 0x1.b26b79c86af24p-45 },
    .{ .invc = 0x1.4400000000000p+0, .logc = -0x1.e27076e2af000p-3, .logctail = -0x1.72f4f543fff10p-46 },
    .{ .invc = 0x1.4200000000000p+0, .logc = -0x1.d5c216b4fc000p-3, .logctail = 0x1.1ba91bbca681bp-45 },
    .{ .invc = 0x1.4000000000000p+0, .logc = -0x1.c8ff7c79aa000p-3, .logctail = 0x1.7794f689f8434p-45 },
    .{ .invc = 0x1.4000000000000p+0, .logc = -0x1.c8ff7c79aa000p-3, .logctail = 0x1.7794f689f8434p-45 },
    .{ .invc = 0x1.3e00000000000p+0, .logc = -0x1.bc286742d9000p-3, .logctail = 0x1.94eb0318bb78fp-46 },
    .{ .invc = 0x1.3c00000000000p+0, .logc = -0x1.af3c94e80c000p-3, .logctail = 0x1.a4e633fcd9066p-52 },
    .{ .invc = 0x1.3a00000000000p+0, .logc = -0x1.a23bc1fe2b000p-3, .logctail = -0x1.58c64dc46c1eap-45 },
    .{ .invc = 0x1.3a00000000000p+0, .logc = -0x1.a23bc1fe2b000p-3, .logctail = -0x1.58c64dc46c1eap-45 },
    .{ .invc = 0x1.3800000000000p+0, .logc = -0x1.9525a9cf45000p-3, .logctail = -0x1.ad1d904c1d4e3p-45 },
    .{ .invc = 0x1.3600000000000p+0, .logc = -0x1.87fa06520d000p-3, .logctail = 0x1.bbdbf7fdbfa09p-45 },
    .{ .invc = 0x1.3400000000000p+0, .logc = -0x1.7ab890210e000p-3, .logctail = 0x1.bdb9072534a58p-45 },
    .{ .invc = 0x1.3400000000000p+0, .logc = -0x1.7ab890210e000p-3, .logctail = 0x1.bdb9072534a58p-45 },
    .{ .invc = 0x1.3200000000000p+0, .logc = -0x1.6d60fe719d000p-3, .logctail = -0x1.0e46aa3b2e266p-46 },
    .{ .invc = 0x1.3000000000000p+0, .logc = -0x1.5ff3070a79000p-3, .logctail = -0x1.e9e439f105039p-46 },
    .{ .invc = 0x1.3000000000000p+0, .logc = -0x1.5ff3070a79000p-3, .logctail = -0x1.e9e439f105039p-46 },
    .{ .invc = 0x1.2e00000000000p+0, .logc = -0x1.526e5e3a1b000p-3, .logctail = -0x1.0de8b90075b8fp-45 },
    .{ .invc = 0x1.2c00000000000p+0, .logc = -0x1.44d2b6ccb8000p-3, .logctail = 0x1.70cc16135783cp-46 },
    .{ .invc = 0x1.2c00000000000p+0, .logc = -0x1.44d2b6ccb8000p-3, .logctail = 0x1.70cc16135783cp-46 },
    .{ .invc = 0x1.2a00000000000p+0, .logc = -0x1.371fc201e9000p-3, .logctail = 0x1.178864d27543ap-48 },
    .{ .invc = 0x1.2800000000000p+0, .logc = -0x1.29552f81ff000p-3, .logctail = -0x1.48d301771c408p-45 },
    .{ .invc = 0x1.2600000000000p+0, .logc = -0x1.1b72ad52f6000p-3, .logctail = -0x1.e80a41811a396p-45 },
    .{ .invc = 0x1.2600000000000p+0, .logc = -0x1.1b72ad52f6000p-3, .logctail = -0x1.e80a41811a396p-45 },
    .{ .invc = 0x1.2400000000000p+0, .logc = -0x1.0d77e7cd09000p-3, .logctail = 0x1.a699688e85bf4p-47 },
    .{ .invc = 0x1.2400000000000p+0, .logc = -0x1.0d77e7cd09000p-3, .logctail = 0x1.a699688e85bf4p-47 },
    .{ .invc = 0x1.2200000000000p+0, .logc = -0x1.fec9131dbe000p-4, .logctail = -0x1.575545ca333f2p-45 },
    .{ .invc = 0x1.2000000000000p+0, .logc = -0x1.e27076e2b0000p-4, .logctail = 0x1.a342c2af0003cp-45 },
    .{ .invc = 0x1.2000000000000p+0, .logc = -0x1.e27076e2b0000p-4, .logctail = 0x1.a342c2af0003cp-45 },
    .{ .invc = 0x1.1e00000000000p+0, .logc = -0x1.c5e548f5bc000p-4, .logctail = -0x1.d0c57585fbe06p-46 },
    .{ .invc = 0x1.1c00000000000p+0, .logc = -0x1.a926d3a4ae000p-4, .logctail = 0x1.53935e85baac8p-45 },
    .{ .invc = 0x1.1c00000000000p+0, .logc = -0x1.a926d3a4ae000p-4, .logctail = 0x1.53935e85baac8p-45 },
    .{ .invc = 0x1.1a00000000000p+0, .logc = -0x1.8c345d631a000p-4, .logctail = 0x1.37c294d2f5668p-46 },
    .{ .invc = 0x1.1a00000000000p+0, .logc = -0x1.8c345d631a000p-4, .logctail = 0x1.37c294d2f5668p-46 },
    .{ .invc = 0x1.1800000000000p+0, .logc = -0x1.6f0d28ae56000p-4, .logctail = -0x1.69737c93373dap-45 },
    .{ .invc = 0x1.1600000000000p+0, .logc = -0x1.51b073f062000p-4, .logctail = 0x1.f025b61c65e57p-46 },
    .{ .invc = 0x1.1600000000000p+0, .logc = -0x1.51b073f062000p-4, .logctail = 0x1.f025b61c65e57p-46 },
    .{ .invc = 0x1.1400000000000p+0, .logc = -0x1.341d7961be000p-4, .logctail = 0x1.c5edaccf913dfp-45 },
    .{ .invc = 0x1.1400000000000p+0, .logc = -0x1.341d7961be000p-4, .logctail = 0x1.c5edaccf913dfp-45 },
    .{ .invc = 0x1.1200000000000p+0, .logc = -0x1.16536eea38000p-4, .logctail = 0x1.47c5e768fa309p-46 },
    .{ .invc = 0x1.1000000000000p+0, .logc = -0x1.f0a30c0118000p-5, .logctail = 0x1.d599e83368e91p-45 },
    .{ .invc = 0x1.1000000000000p+0, .logc = -0x1.f0a30c0118000p-5, .logctail = 0x1.d599e83368e91p-45 },
    .{ .invc = 0x1.0e00000000000p+0, .logc = -0x1.b42dd71198000p-5, .logctail = 0x1.c827ae5d6704cp-46 },
    .{ .invc = 0x1.0e00000000000p+0, .logc = -0x1.b42dd71198000p-5, .logctail = 0x1.c827ae5d6704cp-46 },
    .{ .invc = 0x1.0c00000000000p+0, .logc = -0x1.77458f632c000p-5, .logctail = -0x1.cfc4634f2a1eep-45 },
    .{ .invc = 0x1.0c00000000000p+0, .logc = -0x1.77458f632c000p-5, .logctail = -0x1.cfc4634f2a1eep-45 },
    .{ .invc = 0x1.0a00000000000p+0, .logc = -0x1.39e87b9fec000p-5, .logctail = 0x1.502b7f526feaap-48 },
    .{ .invc = 0x1.0a00000000000p+0, .logc = -0x1.39e87b9fec000p-5, .logctail = 0x1.502b7f526feaap-48 },
    .{ .invc = 0x1.0800000000000p+0, .logc = -0x1.f829b0e780000p-6, .logctail = -0x1.980267c7e09e4p-45 },
    .{ .invc = 0x1.0800000000000p+0, .logc = -0x1.f829b0e780000p-6, .logctail = -0x1.980267c7e09e4p-45 },
    .{ .invc = 0x1.0600000000000p+0, .logc = -0x1.7b91b07d58000p-6, .logctail = -0x1.88d5493faa639p-45 },
    .{ .invc = 0x1.0400000000000p+0, .logc = -0x1.fc0a8b0fc0000p-7, .logctail = -0x1.f1e7cf6d3a69cp-50 },
    .{ .invc = 0x1.0400000000000p+0, .logc = -0x1.fc0a8b0fc0000p-7, .logctail = -0x1.f1e7cf6d3a69cp-50 },
    .{ .invc = 0x1.0200000000000p+0, .logc = -0x1.fe02a6b100000p-8, .logctail = -0x1.9e23f0dda40e4p-46 },
    .{ .invc = 0x1.0200000000000p+0, .logc = -0x1.fe02a6b100000p-8, .logctail = -0x1.9e23f0dda40e4p-46 },
    .{ .invc = 0x1.0000000000000p+0, .logc = 0x0.0000000000000p+0, .logctail = 0x0.0000000000000p+0 },
    .{ .invc = 0x1.0000000000000p+0, .logc = 0x0.0000000000000p+0, .logctail = 0x0.0000000000000p+0 },
    .{ .invc = 0x1.fc00000000000p-1, .logc = 0x1.0101575890000p-7, .logctail = -0x1.0c76b999d2be8p-46 },
    .{ .invc = 0x1.f800000000000p-1, .logc = 0x1.0205658938000p-6, .logctail = -0x1.3dc5b06e2f7d2p-45 },
    .{ .invc = 0x1.f400000000000p-1, .logc = 0x1.8492528c90000p-6, .logctail = -0x1.aa0ba325a0c34p-45 },
    .{ .invc = 0x1.f000000000000p-1, .logc = 0x1.0415d89e74000p-5, .logctail = 0x1.111c05cf1d753p-47 },
    .{ .invc = 0x1.ec00000000000p-1, .logc = 0x1.466aed42e0000p-5, .logctail = -0x1.c167375bdfd28p-45 },
    .{ .invc = 0x1.e800000000000p-1, .logc = 0x1.894aa149fc000p-5, .logctail = -0x1.97995d05a267dp-46 },
    .{ .invc = 0x1.e400000000000p-1, .logc = 0x1.ccb73cdddc000p-5, .logctail = -0x1.a68f247d82807p-46 },
    .{ .invc = 0x1.e200000000000p-1, .logc = 0x1.eea31c006c000p-5, .logctail = -0x1.e113e4fc93b7bp-47 },
    .{ .invc = 0x1.de00000000000p-1, .logc = 0x1.1973bd1466000p-4, .logctail = -0x1.5325d560d9e9bp-45 },
    .{ .invc = 0x1.da00000000000p-1, .logc = 0x1.3bdf5a7d1e000p-4, .logctail = 0x1.cc85ea5db4ed7p-45 },
    .{ .invc = 0x1.d600000000000p-1, .logc = 0x1.5e95a4d97a000p-4, .logctail = -0x1.c69063c5d1d1ep-45 },
    .{ .invc = 0x1.d400000000000p-1, .logc = 0x1.700d30aeac000p-4, .logctail = 0x1.c1e8da99ded32p-49 },
    .{ .invc = 0x1.d000000000000p-1, .logc = 0x1.9335e5d594000p-4, .logctail = 0x1.3115c3abd47dap-45 },
    .{ .invc = 0x1.cc00000000000p-1, .logc = 0x1.b6ac88dad6000p-4, .logctail = -0x1.390802bf768e5p-46 },
    .{ .invc = 0x1.ca00000000000p-1, .logc = 0x1.c885801bc4000p-4, .logctail = 0x1.646d1c65aacd3p-45 },
    .{ .invc = 0x1.c600000000000p-1, .logc = 0x1.ec739830a2000p-4, .logctail = -0x1.dc068afe645e0p-45 },
    .{ .invc = 0x1.c400000000000p-1, .logc = 0x1.fe89139dbe000p-4, .logctail = -0x1.534d64fa10afdp-45 },
    .{ .invc = 0x1.c000000000000p-1, .logc = 0x1.1178e8227e000p-3, .logctail = 0x1.1ef78ce2d07f2p-45 },
    .{ .invc = 0x1.be00000000000p-1, .logc = 0x1.1aa2b7e23f000p-3, .logctail = 0x1.ca78e44389934p-45 },
    .{ .invc = 0x1.ba00000000000p-1, .logc = 0x1.2d1610c868000p-3, .logctail = 0x1.39d6ccb81b4a1p-47 },
    .{ .invc = 0x1.b800000000000p-1, .logc = 0x1.365fcb0159000p-3, .logctail = 0x1.62fa8234b7289p-51 },
    .{ .invc = 0x1.b400000000000p-1, .logc = 0x1.4913d8333b000p-3, .logctail = 0x1.5837954fdb678p-45 },
    .{ .invc = 0x1.b200000000000p-1, .logc = 0x1.527e5e4a1b000p-3, .logctail = 0x1.633e8e5697dc7p-45 },
    .{ .invc = 0x1.ae00000000000p-1, .logc = 0x1.6574ebe8c1000p-3, .logctail = 0x1.9cf8b2c3c2e78p-46 },
    .{ .invc = 0x1.ac00000000000p-1, .logc = 0x1.6f0128b757000p-3, .logctail = -0x1.5118de59c21e1p-45 },
    .{ .invc = 0x1.aa00000000000p-1, .logc = 0x1.7898d85445000p-3, .logctail = -0x1.c661070914305p-46 },
    .{ .invc = 0x1.a600000000000p-1, .logc = 0x1.8beafeb390000p-3, .logctail = -0x1.73d54aae92cd1p-47 },
    .{ .invc = 0x1.a400000000000p-1, .logc = 0x1.95a5adcf70000p-3, .logctail = 0x1.7f22858a0ff6fp-47 },
    .{ .invc = 0x1.a000000000000p-1, .logc = 0x1.a93ed3c8ae000p-3, .logctail = -0x1.8724350562169p-45 },
    .{ .invc = 0x1.9e00000000000p-1, .logc = 0x1.b31d8575bd000p-3, .logctail = -0x1.c358d4eace1aap-47 },
    .{ .invc = 0x1.9c00000000000p-1, .logc = 0x1.bd087383be000p-3, .logctail = -0x1.d4bc4595412b6p-45 },
    .{ .invc = 0x1.9a00000000000p-1, .logc = 0x1.c6ffbc6f01000p-3, .logctail = -0x1.1ec72c5962bd2p-48 },
    .{ .invc = 0x1.9600000000000p-1, .logc = 0x1.db13db0d49000p-3, .logctail = -0x1.aff2af715b035p-45 },
    .{ .invc = 0x1.9400000000000p-1, .logc = 0x1.e530effe71000p-3, .logctail = 0x1.212276041f430p-51 },
    .{ .invc = 0x1.9200000000000p-1, .logc = 0x1.ef5ade4dd0000p-3, .logctail = -0x1.a211565bb8e11p-51 },
    .{ .invc = 0x1.9000000000000p-1, .logc = 0x1.f991c6cb3b000p-3, .logctail = 0x1.bcbecca0cdf30p-46 },
    .{ .invc = 0x1.8c00000000000p-1, .logc = 0x1.07138604d5800p-2, .logctail = 0x1.89cdb16ed4e91p-48 },
    .{ .invc = 0x1.8a00000000000p-1, .logc = 0x1.0c42d67616000p-2, .logctail = 0x1.7188b163ceae9p-45 },
    .{ .invc = 0x1.8800000000000p-1, .logc = 0x1.1178e8227e800p-2, .logctail = -0x1.c210e63a5f01cp-45 },
    .{ .invc = 0x1.8600000000000p-1, .logc = 0x1.16b5ccbacf800p-2, .logctail = 0x1.b9acdf7a51681p-45 },
    .{ .invc = 0x1.8400000000000p-1, .logc = 0x1.1bf99635a6800p-2, .logctail = 0x1.ca6ed5147bdb7p-45 },
    .{ .invc = 0x1.8200000000000p-1, .logc = 0x1.214456d0eb800p-2, .logctail = 0x1.a87deba46baeap-47 },
    .{ .invc = 0x1.7e00000000000p-1, .logc = 0x1.2bef07cdc9000p-2, .logctail = 0x1.a9cfa4a5004f4p-45 },
    .{ .invc = 0x1.7c00000000000p-1, .logc = 0x1.314f1e1d36000p-2, .logctail = -0x1.8e27ad3213cb8p-45 },
    .{ .invc = 0x1.7a00000000000p-1, .logc = 0x1.36b6776be1000p-2, .logctail = 0x1.16ecdb0f177c8p-46 },
    .{ .invc = 0x1.7800000000000p-1, .logc = 0x1.3c25277333000p-2, .logctail = 0x1.83b54b606bd5cp-46 },
    .{ .invc = 0x1.7600000000000p-1, .logc = 0x1.419b423d5e800p-2, .logctail = 0x1.8e436ec90e09dp-47 },
    .{ .invc = 0x1.7400000000000p-1, .logc = 0x1.4718dc271c800p-2, .logctail = -0x1.f27ce0967d675p-45 },
    .{ .invc = 0x1.7200000000000p-1, .logc = 0x1.4c9e09e173000p-2, .logctail = -0x1.e20891b0ad8a4p-45 },
    .{ .invc = 0x1.7000000000000p-1, .logc = 0x1.522ae0738a000p-2, .logctail = 0x1.ebe708164c759p-45 },
    .{ .invc = 0x1.6e00000000000p-1, .logc = 0x1.57bf753c8d000p-2, .logctail = 0x1.fadedee5d40efp-46 },
    .{ .invc = 0x1.6c00000000000p-1, .logc = 0x1.5d5bddf596000p-2, .logctail = -0x1.a0b2a08a465dcp-47 },
};

inline fn top16(x: f64) u32 {
    return @intCast(asU64(x) >> 48);
}

fn divzero() f64 {
    return -std.math.inf(f64);
}

// The log tables (`__log_data`, LOG_TABLE_BITS 7, LOG_POLY_ORDER 6,
// LOG_POLY1_ORDER 12).
const log_tab_n = 128;
const log_tab_off: u64 = 0x3fe6000000000000;
const log_a = [_]f64{
    -0x1.0000000000001p-1,
    0x1.555555551305bp-2,
    -0x1.fffffffeb459p-3,
    0x1.999b324f10111p-3,
    -0x1.55575e506c89fp-3,
};
const log_b = [_]f64{
    -0x1p-1,               0x1.5555555555577p-2, -0x1.ffffffffffdcbp-3, 0x1.999999995dd0cp-3,
    -0x1.55555556745a7p-3, 0x1.24924a344de3p-3,  -0x1.fffffa4423d65p-4, 0x1.c7184282ad6cap-4,
    -0x1.999eb43b068ffp-4, 0x1.78182f7afd085p-4, -0x1.5521375d145cdp-4,
};

/// glibc's `log`. Where GCC contracts a product used only by additions
/// into each of them, this does too.
pub fn log(x: f64) f64 {
    var ix = asU64(x);
    const top = top16(x);
    const lo_bound = asU64(1.0 - 0x1p-4);
    const hi_bound = asU64(1.0 + 0x1.09p-4);
    if (ix -% lo_bound < hi_bound - lo_bound) {
        if (ix == asU64(1.0)) return 0;
        const r = x - 1.0;
        const r2 = r * r;
        const r3 = r * r2;
        const inner = mad(r3, log_b[10], mad(r2, log_b[9], mad(r, log_b[8], log_b[7])));
        const middle = mad(r3, inner, mad(r2, log_b[6], mad(r, log_b[5], log_b[4])));
        const outer = mad(r3, middle, mad(r2, log_b[3], mad(r, log_b[2], log_b[1])));
        // r * 2^27 and rhi * rhi * log_b[0] are exact, so contraction cannot
        // change them.
        const w = r * 0x1p27;
        const rhi = r + w - w;
        const rlo = r - rhi;
        const w2 = rhi * rhi * log_b[0];
        const hi = r + w2;
        var lo = r - hi + w2;
        lo = mad(log_b[0] * rlo, rhi + r, lo);
        const y = mad(r3, outer, lo);
        return y + hi;
    }
    if (top -% 0x0010 >= 0x7ff0 - 0x0010) {
        if (ix *% 2 == 0) return divzero();
        if (ix == asU64(std.math.inf(f64))) return x;
        if ((top & 0x8000) != 0 or (top & 0x7ff0) == 0x7ff0) return invalid(x);
        ix = asU64(x * 0x1p52);
        ix -%= 52 << 52;
    }
    const tmp = ix -% log_tab_off;
    const i: usize = @intCast((tmp >> (52 - 7)) % log_tab_n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const invc = log_tab[i].invc;
    const logc = log_tab[i].logc;
    const z = asF64(iz);
    const r = if (has_fma) @mulAdd(f64, z, invc, -1.0) else (z - log_tab2[i].chi - log_tab2[i].clo) * invc;
    const kd: f64 = @floatFromInt(k);
    const w = mad(kd, ln2_hi, logc);
    const hi = w + r;
    const lo = mad(kd, ln2_lo, w - hi + r);
    const r2 = r * r;
    const q = mad(r2, mad(r, log_a[4], log_a[3]), mad(r, log_a[2], log_a[1]));
    const y = mad(r * r2, q, mad(r2, log_a[0], lo));
    return y + hi;
}

// The log2 tables (`__log2_data`, LOG2_TABLE_BITS 6, LOG2_POLY_ORDER 7,
// LOG2_POLY1_ORDER 11).
const log2_tab_n = 64;
const inv_ln2_hi = 0x1.7154765200000p+0;
const inv_ln2_lo = 0x1.705fc2eefa200p-33;
const log2_a = [_]f64{
    -0x1.71547652b8339p-1,
    0x1.ec709dc3a04bep-2,
    -0x1.7154764702ffbp-2,
    0x1.2776c50034c48p-2,
    -0x1.ec7b328ea92bcp-3,
    0x1.a6225e117f92ep-3,
};
const log2_b = [_]f64{
    -0x1.71547652b82fep-1, 0x1.ec709dc3a03f7p-2, -0x1.71547652b7c3fp-2, 0x1.2776c50f05be4p-2,
    -0x1.ec709dd768fe5p-3, 0x1.a61761ec4e736p-3, -0x1.7153fbc64a79bp-3, 0x1.484d154f01b4ap-3,
    -0x1.289e4a72c383cp-3, 0x1.0b32f285aee66p-3,
};

/// glibc's `log2`.
pub fn log2(x: f64) f64 {
    var ix = asU64(x);
    const top = top16(x);
    const lo_bound = asU64(1.0 - 0x1.5b51p-5);
    const hi_bound = asU64(1.0 + 0x1.6ab2p-5);
    if (ix -% lo_bound < hi_bound - lo_bound) {
        if (ix == asU64(1.0)) return 0;
        const r = x - 1.0;
        var hi: f64 = undefined;
        var lo: f64 = undefined;
        if (has_fma) {
            hi = r * inv_ln2_hi;
            lo = @mulAdd(f64, r, inv_ln2_lo, @mulAdd(f64, r, inv_ln2_hi, -hi));
        } else {
            const rhi = asF64(asU64(r) & (~@as(u64, 0) << 32));
            const rlo = r - rhi;
            hi = rhi * inv_ln2_hi;
            lo = rlo * inv_ln2_hi + r * inv_ln2_lo;
        }
        const r2 = r * r;
        const r4 = r2 * r2;
        // p = r2 * pb is used only by additions, so GCC fuses it into both.
        const pb = mad(r, log2_b[1], log2_b[0]);
        var y = mad(r2, pb, hi);
        lo += mad(r2, pb, hi - y);
        const inner2 = mad(r2, mad(r, log2_b[9], log2_b[8]), mad(r, log2_b[7], log2_b[6]));
        const inner1 = mad(r4, inner2, mad(r2, mad(r, log2_b[5], log2_b[4]), mad(r, log2_b[3], log2_b[2])));
        lo = mad(r4, inner1, lo);
        y += lo;
        return y;
    }
    if (top -% 0x0010 >= 0x7ff0 - 0x0010) {
        if (ix *% 2 == 0) return divzero();
        if (ix == asU64(std.math.inf(f64))) return x;
        if ((top & 0x8000) != 0 or (top & 0x7ff0) == 0x7ff0) return invalid(x);
        ix = asU64(x * 0x1p52);
        ix -%= 52 << 52;
    }
    const tmp = ix -% log_tab_off;
    const i: usize = @intCast((tmp >> (52 - 6)) % log2_tab_n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const invc = log2_tab[i].invc;
    const logc = log2_tab[i].logc;
    const z = asF64(iz);
    const kd: f64 = @floatFromInt(k);
    var r: f64 = undefined;
    var t1: f64 = undefined;
    var t2: f64 = undefined;
    if (has_fma) {
        r = @mulAdd(f64, z, invc, -1.0);
        t1 = r * inv_ln2_hi;
        t2 = @mulAdd(f64, r, inv_ln2_lo, @mulAdd(f64, r, inv_ln2_hi, -t1));
    } else {
        r = (z - log2_tab2[i].chi - log2_tab2[i].clo) * invc;
        const rhi = asF64(asU64(r) & (~@as(u64, 0) << 32));
        const rlo = r - rhi;
        t1 = rhi * inv_ln2_hi;
        t2 = rlo * inv_ln2_hi + r * inv_ln2_lo;
    }
    const t3 = kd + logc;
    const hi = t3 + t1;
    const lo = t3 - hi + t1 + t2;
    const r2 = r * r;
    const r4 = r2 * r2;
    const p01 = mad(r, log2_a[1], log2_a[0]);
    const p = mad(r4, mad(r, log2_a[5], log2_a[4]), mad(r2, mad(r, log2_a[3], log2_a[2]), p01));
    return mad(r2, p, lo) + hi;
}

/// glibc's `log10` (fdlibm's e_log10.c, built without FMA, calling the
/// `log` above), with the wrapper's +NaN for negative numbers.
pub fn log10(x_in: f64) f64 {
    const two54 = 1.80143985094819840000e+16;
    const ivln10 = 4.34294481903251816668e-01;
    const log10_2hi = 3.01029995663611771306e-01;
    const log10_2lo = 3.69423907715893078616e-13;
    var x = x_in;
    var hx: i64 = @bitCast(x);
    var k: i32 = 0;
    if (hx < 0x0010000000000000) {
        if (hx & 0x7fffffffffffffff == 0) return -std.math.inf(f64);
        if (hx < 0) return if (std.math.isNan(x)) x + x else std.math.nan(f64);
        k -= 54;
        x *= two54;
        hx = @bitCast(x);
    }
    if (hx >= 0x7ff0000000000000) return x + x;
    k += @as(i32, @intCast(hx >> 52)) - 1023;
    const i: i64 = @intCast(@as(u32, @bitCast(k)) >> 31);
    hx = (hx & 0x000fffffffffffff) | ((0x3ff - i) << 52);
    const y: f64 = @floatFromInt(k + @as(i32, @intCast(i)));
    x = @bitCast(hx);
    const z = y * log10_2lo + ivln10 * log(x);
    return z + y * log10_2hi;
}

const log_tab = [_]struct { invc: f64, logc: f64 }{
    .{ .invc = 0x1.734f0c3e0de9fp+0, .logc = -0x1.7cc7f79e69000p-2 },
    .{ .invc = 0x1.713786a2ce91fp+0, .logc = -0x1.76feec20d0000p-2 },
    .{ .invc = 0x1.6f26008fab5a0p+0, .logc = -0x1.713e31351e000p-2 },
    .{ .invc = 0x1.6d1a61f138c7dp+0, .logc = -0x1.6b85b38287800p-2 },
    .{ .invc = 0x1.6b1490bc5b4d1p+0, .logc = -0x1.65d5590807800p-2 },
    .{ .invc = 0x1.69147332f0cbap+0, .logc = -0x1.602d076180000p-2 },
    .{ .invc = 0x1.6719f18224223p+0, .logc = -0x1.5a8ca86909000p-2 },
    .{ .invc = 0x1.6524f99a51ed9p+0, .logc = -0x1.54f4356035000p-2 },
    .{ .invc = 0x1.63356aa8f24c4p+0, .logc = -0x1.4f637c36b4000p-2 },
    .{ .invc = 0x1.614b36b9ddc14p+0, .logc = -0x1.49da7fda85000p-2 },
    .{ .invc = 0x1.5f66452c65c4cp+0, .logc = -0x1.445923989a800p-2 },
    .{ .invc = 0x1.5d867b5912c4fp+0, .logc = -0x1.3edf439b0b800p-2 },
    .{ .invc = 0x1.5babccb5b90dep+0, .logc = -0x1.396ce448f7000p-2 },
    .{ .invc = 0x1.59d61f2d91a78p+0, .logc = -0x1.3401e17bda000p-2 },
    .{ .invc = 0x1.5805612465687p+0, .logc = -0x1.2e9e2ef468000p-2 },
    .{ .invc = 0x1.56397cee76bd3p+0, .logc = -0x1.2941b3830e000p-2 },
    .{ .invc = 0x1.54725e2a77f93p+0, .logc = -0x1.23ec58cda8800p-2 },
    .{ .invc = 0x1.52aff42064583p+0, .logc = -0x1.1e9e129279000p-2 },
    .{ .invc = 0x1.50f22dbb2bddfp+0, .logc = -0x1.1956d2b48f800p-2 },
    .{ .invc = 0x1.4f38f4734ded7p+0, .logc = -0x1.141679ab9f800p-2 },
    .{ .invc = 0x1.4d843cfde2840p+0, .logc = -0x1.0edd094ef9800p-2 },
    .{ .invc = 0x1.4bd3ec078a3c8p+0, .logc = -0x1.09aa518db1000p-2 },
    .{ .invc = 0x1.4a27fc3e0258ap+0, .logc = -0x1.047e65263b800p-2 },
    .{ .invc = 0x1.4880524d48434p+0, .logc = -0x1.feb224586f000p-3 },
    .{ .invc = 0x1.46dce1b192d0bp+0, .logc = -0x1.f474a7517b000p-3 },
    .{ .invc = 0x1.453d9d3391854p+0, .logc = -0x1.ea4443d103000p-3 },
    .{ .invc = 0x1.43a2744b4845ap+0, .logc = -0x1.e020d44e9b000p-3 },
    .{ .invc = 0x1.420b54115f8fbp+0, .logc = -0x1.d60a22977f000p-3 },
    .{ .invc = 0x1.40782da3ef4b1p+0, .logc = -0x1.cc00104959000p-3 },
    .{ .invc = 0x1.3ee8f5d57fe8fp+0, .logc = -0x1.c202956891000p-3 },
    .{ .invc = 0x1.3d5d9a00b4ce9p+0, .logc = -0x1.b81178d811000p-3 },
    .{ .invc = 0x1.3bd60c010c12bp+0, .logc = -0x1.ae2c9ccd3d000p-3 },
    .{ .invc = 0x1.3a5242b75dab8p+0, .logc = -0x1.a45402e129000p-3 },
    .{ .invc = 0x1.38d22cd9fd002p+0, .logc = -0x1.9a877681df000p-3 },
    .{ .invc = 0x1.3755bc5847a1cp+0, .logc = -0x1.90c6d69483000p-3 },
    .{ .invc = 0x1.35dce49ad36e2p+0, .logc = -0x1.87120a645c000p-3 },
    .{ .invc = 0x1.34679984dd440p+0, .logc = -0x1.7d68fb4143000p-3 },
    .{ .invc = 0x1.32f5cceffcb24p+0, .logc = -0x1.73cb83c627000p-3 },
    .{ .invc = 0x1.3187775a10d49p+0, .logc = -0x1.6a39a9b376000p-3 },
    .{ .invc = 0x1.301c8373e3990p+0, .logc = -0x1.60b3154b7a000p-3 },
    .{ .invc = 0x1.2eb4ebb95f841p+0, .logc = -0x1.5737d76243000p-3 },
    .{ .invc = 0x1.2d50a0219a9d1p+0, .logc = -0x1.4dc7b8fc23000p-3 },
    .{ .invc = 0x1.2bef9a8b7fd2ap+0, .logc = -0x1.4462c51d20000p-3 },
    .{ .invc = 0x1.2a91c7a0c1babp+0, .logc = -0x1.3b08abc830000p-3 },
    .{ .invc = 0x1.293726014b530p+0, .logc = -0x1.31b996b490000p-3 },
    .{ .invc = 0x1.27dfa5757a1f5p+0, .logc = -0x1.2875490a44000p-3 },
    .{ .invc = 0x1.268b39b1d3bbfp+0, .logc = -0x1.1f3b9f879a000p-3 },
    .{ .invc = 0x1.2539d838ff5bdp+0, .logc = -0x1.160c8252ca000p-3 },
    .{ .invc = 0x1.23eb7aac9083bp+0, .logc = -0x1.0ce7f57f72000p-3 },
    .{ .invc = 0x1.22a012ba940b6p+0, .logc = -0x1.03cdc49fea000p-3 },
    .{ .invc = 0x1.2157996cc4132p+0, .logc = -0x1.f57bdbc4b8000p-4 },
    .{ .invc = 0x1.201201dd2fc9bp+0, .logc = -0x1.e370896404000p-4 },
    .{ .invc = 0x1.1ecf4494d480bp+0, .logc = -0x1.d17983ef94000p-4 },
    .{ .invc = 0x1.1d8f5528f6569p+0, .logc = -0x1.bf9674ed8a000p-4 },
    .{ .invc = 0x1.1c52311577e7cp+0, .logc = -0x1.adc79202f6000p-4 },
    .{ .invc = 0x1.1b17c74cb26e9p+0, .logc = -0x1.9c0c3e7288000p-4 },
    .{ .invc = 0x1.19e010c2c1ab6p+0, .logc = -0x1.8a646b372c000p-4 },
    .{ .invc = 0x1.18ab07bb670bdp+0, .logc = -0x1.78d01b3ac0000p-4 },
    .{ .invc = 0x1.1778a25efbcb6p+0, .logc = -0x1.674f145380000p-4 },
    .{ .invc = 0x1.1648d354c31dap+0, .logc = -0x1.55e0e6d878000p-4 },
    .{ .invc = 0x1.151b990275fddp+0, .logc = -0x1.4485cdea1e000p-4 },
    .{ .invc = 0x1.13f0ea432d24cp+0, .logc = -0x1.333d94d6aa000p-4 },
    .{ .invc = 0x1.12c8b7210f9dap+0, .logc = -0x1.22079f8c56000p-4 },
    .{ .invc = 0x1.11a3028ecb531p+0, .logc = -0x1.10e4698622000p-4 },
    .{ .invc = 0x1.107fbda8434afp+0, .logc = -0x1.ffa6c6ad20000p-5 },
    .{ .invc = 0x1.0f5ee0f4e6bb3p+0, .logc = -0x1.dda8d4a774000p-5 },
    .{ .invc = 0x1.0e4065d2a9fcep+0, .logc = -0x1.bbcece4850000p-5 },
    .{ .invc = 0x1.0d244632ca521p+0, .logc = -0x1.9a1894012c000p-5 },
    .{ .invc = 0x1.0c0a77ce2981ap+0, .logc = -0x1.788583302c000p-5 },
    .{ .invc = 0x1.0af2f83c636d1p+0, .logc = -0x1.5715e67d68000p-5 },
    .{ .invc = 0x1.09ddb98a01339p+0, .logc = -0x1.35c8a49658000p-5 },
    .{ .invc = 0x1.08cabaf52e7dfp+0, .logc = -0x1.149e364154000p-5 },
    .{ .invc = 0x1.07b9f2f4e28fbp+0, .logc = -0x1.e72c082eb8000p-6 },
    .{ .invc = 0x1.06ab58c358f19p+0, .logc = -0x1.a55f152528000p-6 },
    .{ .invc = 0x1.059eea5ecf92cp+0, .logc = -0x1.63d62cf818000p-6 },
    .{ .invc = 0x1.04949cdd12c90p+0, .logc = -0x1.228fb8caa0000p-6 },
    .{ .invc = 0x1.038c6c6f0ada9p+0, .logc = -0x1.c317b20f90000p-7 },
    .{ .invc = 0x1.02865137932a9p+0, .logc = -0x1.419355daa0000p-7 },
    .{ .invc = 0x1.0182427ea7348p+0, .logc = -0x1.81203c2ec0000p-8 },
    .{ .invc = 0x1.008040614b195p+0, .logc = -0x1.0040979240000p-9 },
    .{ .invc = 0x1.fe01ff726fa1ap-1, .logc = 0x1.feff384900000p-9 },
    .{ .invc = 0x1.fa11cc261ea74p-1, .logc = 0x1.7dc41353d0000p-7 },
    .{ .invc = 0x1.f6310b081992ep-1, .logc = 0x1.3cea3c4c28000p-6 },
    .{ .invc = 0x1.f25f63ceeadcdp-1, .logc = 0x1.b9fc114890000p-6 },
    .{ .invc = 0x1.ee9c8039113e7p-1, .logc = 0x1.1b0d8ce110000p-5 },
    .{ .invc = 0x1.eae8078cbb1abp-1, .logc = 0x1.58a5bd001c000p-5 },
    .{ .invc = 0x1.e741aa29d0c9bp-1, .logc = 0x1.95c8340d88000p-5 },
    .{ .invc = 0x1.e3a91830a99b5p-1, .logc = 0x1.d276aef578000p-5 },
    .{ .invc = 0x1.e01e009609a56p-1, .logc = 0x1.07598e598c000p-4 },
    .{ .invc = 0x1.dca01e577bb98p-1, .logc = 0x1.253f5e30d2000p-4 },
    .{ .invc = 0x1.d92f20b7c9103p-1, .logc = 0x1.42edd8b380000p-4 },
    .{ .invc = 0x1.d5cac66fb5ccep-1, .logc = 0x1.606598757c000p-4 },
    .{ .invc = 0x1.d272caa5ede9dp-1, .logc = 0x1.7da76356a0000p-4 },
    .{ .invc = 0x1.cf26e3e6b2ccdp-1, .logc = 0x1.9ab434e1c6000p-4 },
    .{ .invc = 0x1.cbe6da2a77902p-1, .logc = 0x1.b78c7bb0d6000p-4 },
    .{ .invc = 0x1.c8b266d37086dp-1, .logc = 0x1.d431332e72000p-4 },
    .{ .invc = 0x1.c5894bd5d5804p-1, .logc = 0x1.f0a3171de6000p-4 },
    .{ .invc = 0x1.c26b533bb9f8cp-1, .logc = 0x1.067152b914000p-3 },
    .{ .invc = 0x1.bf583eeece73fp-1, .logc = 0x1.147858292b000p-3 },
    .{ .invc = 0x1.bc4fd75db96c1p-1, .logc = 0x1.2266ecdca3000p-3 },
    .{ .invc = 0x1.b951e0c864a28p-1, .logc = 0x1.303d7a6c55000p-3 },
    .{ .invc = 0x1.b65e2c5ef3e2cp-1, .logc = 0x1.3dfc33c331000p-3 },
    .{ .invc = 0x1.b374867c9888bp-1, .logc = 0x1.4ba366b7a8000p-3 },
    .{ .invc = 0x1.b094b211d304ap-1, .logc = 0x1.5933928d1f000p-3 },
    .{ .invc = 0x1.adbe885f2ef7ep-1, .logc = 0x1.66acd2418f000p-3 },
    .{ .invc = 0x1.aaf1d31603da2p-1, .logc = 0x1.740f8ec669000p-3 },
    .{ .invc = 0x1.a82e63fd358a7p-1, .logc = 0x1.815c0f51af000p-3 },
    .{ .invc = 0x1.a5740ef09738bp-1, .logc = 0x1.8e92954f68000p-3 },
    .{ .invc = 0x1.a2c2a90ab4b27p-1, .logc = 0x1.9bb3602f84000p-3 },
    .{ .invc = 0x1.a01a01393f2d1p-1, .logc = 0x1.a8bed1c2c0000p-3 },
    .{ .invc = 0x1.9d79f24db3c1bp-1, .logc = 0x1.b5b515c01d000p-3 },
    .{ .invc = 0x1.9ae2505c7b190p-1, .logc = 0x1.c2967ccbcc000p-3 },
    .{ .invc = 0x1.9852ef297ce2fp-1, .logc = 0x1.cf635d5486000p-3 },
    .{ .invc = 0x1.95cbaeea44b75p-1, .logc = 0x1.dc1bd3446c000p-3 },
    .{ .invc = 0x1.934c69de74838p-1, .logc = 0x1.e8c01b8cfe000p-3 },
    .{ .invc = 0x1.90d4f2f6752e6p-1, .logc = 0x1.f5509c0179000p-3 },
    .{ .invc = 0x1.8e6528effd79dp-1, .logc = 0x1.00e6c121fb800p-2 },
    .{ .invc = 0x1.8bfce9fcc007cp-1, .logc = 0x1.071b80e93d000p-2 },
    .{ .invc = 0x1.899c0dabec30ep-1, .logc = 0x1.0d46b9e867000p-2 },
    .{ .invc = 0x1.87427aa2317fbp-1, .logc = 0x1.13687334bd000p-2 },
    .{ .invc = 0x1.84f00acb39a08p-1, .logc = 0x1.1980d67234800p-2 },
    .{ .invc = 0x1.82a49e8653e55p-1, .logc = 0x1.1f8ffe0cc8000p-2 },
    .{ .invc = 0x1.8060195f40260p-1, .logc = 0x1.2595fd7636800p-2 },
    .{ .invc = 0x1.7e22563e0a329p-1, .logc = 0x1.2b9300914a800p-2 },
    .{ .invc = 0x1.7beb377dcb5adp-1, .logc = 0x1.3187210436000p-2 },
    .{ .invc = 0x1.79baa679725c2p-1, .logc = 0x1.377266dec1800p-2 },
    .{ .invc = 0x1.77907f2170657p-1, .logc = 0x1.3d54ffbaf3000p-2 },
    .{ .invc = 0x1.756cadbd6130cp-1, .logc = 0x1.432eee32fe000p-2 },
};

const log_tab2 = [_]struct { chi: f64, clo: f64 }{
    .{ .chi = 0x1.61000014fb66bp-1, .clo = 0x1.e026c91425b3cp-56 },
    .{ .chi = 0x1.63000034db495p-1, .clo = 0x1.dbfea48005d41p-55 },
    .{ .chi = 0x1.650000d94d478p-1, .clo = 0x1.e7fa786d6a5b7p-55 },
    .{ .chi = 0x1.67000074e6fadp-1, .clo = 0x1.1fcea6b54254cp-57 },
    .{ .chi = 0x1.68ffffedf0faep-1, .clo = -0x1.c7e274c590efdp-56 },
    .{ .chi = 0x1.6b0000763c5bcp-1, .clo = -0x1.ac16848dcda01p-55 },
    .{ .chi = 0x1.6d0001e5cc1f6p-1, .clo = 0x1.33f1c9d499311p-55 },
    .{ .chi = 0x1.6efffeb05f63ep-1, .clo = -0x1.e80041ae22d53p-56 },
    .{ .chi = 0x1.710000e86978p-1, .clo = 0x1.bff6671097952p-56 },
    .{ .chi = 0x1.72ffffc67e912p-1, .clo = 0x1.c00e226bd8724p-55 },
    .{ .chi = 0x1.74fffdf81116ap-1, .clo = -0x1.e02916ef101d2p-57 },
    .{ .chi = 0x1.770000f679c9p-1, .clo = -0x1.7fc71cd549c74p-57 },
    .{ .chi = 0x1.78ffffa7ec835p-1, .clo = 0x1.1bec19ef50483p-55 },
    .{ .chi = 0x1.7affffe20c2e6p-1, .clo = -0x1.07e1729cc6465p-56 },
    .{ .chi = 0x1.7cfffed3fc9p-1, .clo = -0x1.08072087b8b1cp-55 },
    .{ .chi = 0x1.7efffe9261a76p-1, .clo = 0x1.dc0286d9df9aep-55 },
    .{ .chi = 0x1.81000049ca3e8p-1, .clo = 0x1.97fd251e54c33p-55 },
    .{ .chi = 0x1.8300017932c8fp-1, .clo = -0x1.afee9b630f381p-55 },
    .{ .chi = 0x1.850000633739cp-1, .clo = 0x1.9bfbf6b6535bcp-55 },
    .{ .chi = 0x1.87000204289c6p-1, .clo = -0x1.bbf65f3117b75p-55 },
    .{ .chi = 0x1.88fffebf57904p-1, .clo = -0x1.9006ea23dcb57p-55 },
    .{ .chi = 0x1.8b00022bc04dfp-1, .clo = -0x1.d00df38e04b0ap-56 },
    .{ .chi = 0x1.8cfffe50c1b8ap-1, .clo = -0x1.8007146ff9f05p-55 },
    .{ .chi = 0x1.8effffc918e43p-1, .clo = 0x1.3817bd07a7038p-55 },
    .{ .chi = 0x1.910001efa5fc7p-1, .clo = 0x1.93e9176dfb403p-55 },
    .{ .chi = 0x1.9300013467bb9p-1, .clo = 0x1.f804e4b980276p-56 },
    .{ .chi = 0x1.94fffe6ee076fp-1, .clo = -0x1.f7ef0d9ff622ep-55 },
    .{ .chi = 0x1.96fffde3c12d1p-1, .clo = -0x1.082aa962638bap-56 },
    .{ .chi = 0x1.98ffff4458a0dp-1, .clo = -0x1.7801b9164a8efp-55 },
    .{ .chi = 0x1.9afffdd982e3ep-1, .clo = -0x1.740e08a5a9337p-55 },
    .{ .chi = 0x1.9cfffed49fb66p-1, .clo = 0x1.fce08c19bep-60 },
    .{ .chi = 0x1.9f00020f19c51p-1, .clo = -0x1.a3faa27885b0ap-55 },
    .{ .chi = 0x1.a10001145b006p-1, .clo = 0x1.4ff489958da56p-56 },
    .{ .chi = 0x1.a300007bbf6fap-1, .clo = 0x1.cbeab8a2b6d18p-55 },
    .{ .chi = 0x1.a500010971d79p-1, .clo = 0x1.8fecadd78793p-55 },
    .{ .chi = 0x1.a70001df52e48p-1, .clo = -0x1.f41763dd8abdbp-55 },
    .{ .chi = 0x1.a90001c593352p-1, .clo = -0x1.ebf0284c27612p-55 },
    .{ .chi = 0x1.ab0002a4f3e4bp-1, .clo = -0x1.9fd043cff3f5fp-57 },
    .{ .chi = 0x1.acfffd7ae1ed1p-1, .clo = -0x1.23ee7129070b4p-55 },
    .{ .chi = 0x1.aefffee510478p-1, .clo = 0x1.a063ee00edea3p-57 },
    .{ .chi = 0x1.b0fffdb650d5bp-1, .clo = 0x1.a06c8381f0ab9p-58 },
    .{ .chi = 0x1.b2ffffeaaca57p-1, .clo = -0x1.9011e74233c1dp-56 },
    .{ .chi = 0x1.b4fffd995badcp-1, .clo = -0x1.9ff1068862a9fp-56 },
    .{ .chi = 0x1.b7000249e659cp-1, .clo = 0x1.aff45d0864f3ep-55 },
    .{ .chi = 0x1.b8ffff987164p-1, .clo = 0x1.cfe7796c2c3f9p-56 },
    .{ .chi = 0x1.bafffd204cb4fp-1, .clo = -0x1.3ff27eef22bc4p-57 },
    .{ .chi = 0x1.bcfffd2415c45p-1, .clo = -0x1.cffb7ee3bea21p-57 },
    .{ .chi = 0x1.beffff86309dfp-1, .clo = -0x1.14103972e0b5cp-55 },
    .{ .chi = 0x1.c0fffe1b57653p-1, .clo = 0x1.bc16494b76a19p-55 },
    .{ .chi = 0x1.c2ffff1fa57e3p-1, .clo = -0x1.4feef8d30c6edp-57 },
    .{ .chi = 0x1.c4fffdcbfe424p-1, .clo = -0x1.43f68bcec4775p-55 },
    .{ .chi = 0x1.c6fffed54b9f7p-1, .clo = 0x1.47ea3f053e0ecp-55 },
    .{ .chi = 0x1.c8fffeb998fd5p-1, .clo = 0x1.383068df992f1p-56 },
    .{ .chi = 0x1.cb0002125219ap-1, .clo = -0x1.8fd8e64180e04p-57 },
    .{ .chi = 0x1.ccfffdd94469cp-1, .clo = 0x1.e7ebe1cc7ea72p-55 },
    .{ .chi = 0x1.cefffeafdc476p-1, .clo = 0x1.ebe39ad9f88fep-55 },
    .{ .chi = 0x1.d1000169af82bp-1, .clo = 0x1.57d91a8b95a71p-56 },
    .{ .chi = 0x1.d30000d0ff71dp-1, .clo = 0x1.9c1906970c7dap-55 },
    .{ .chi = 0x1.d4fffea790fc4p-1, .clo = -0x1.80e37c558fe0cp-58 },
    .{ .chi = 0x1.d70002edc87e5p-1, .clo = -0x1.f80d64dc10f44p-56 },
    .{ .chi = 0x1.d900021dc82aap-1, .clo = -0x1.47c8f94fd5c5cp-56 },
    .{ .chi = 0x1.dafffd86b0283p-1, .clo = 0x1.c7f1dc521617ep-55 },
    .{ .chi = 0x1.dd000296c4739p-1, .clo = 0x1.8019eb2ffb153p-55 },
    .{ .chi = 0x1.defffe54490f5p-1, .clo = 0x1.e00d2c652cc89p-57 },
    .{ .chi = 0x1.e0fffcdabf694p-1, .clo = -0x1.f8340202d69d2p-56 },
    .{ .chi = 0x1.e2fffdb52c8ddp-1, .clo = 0x1.b00c1ca1b0864p-56 },
    .{ .chi = 0x1.e4ffff24216efp-1, .clo = 0x1.2ffa8b094ab51p-56 },
    .{ .chi = 0x1.e6fffe88a5e11p-1, .clo = -0x1.7f673b1efbe59p-58 },
    .{ .chi = 0x1.e9000119eff0dp-1, .clo = -0x1.4808d5e0bc801p-55 },
    .{ .chi = 0x1.eafffdfa51744p-1, .clo = 0x1.80006d54320b5p-56 },
    .{ .chi = 0x1.ed0001a127fa1p-1, .clo = -0x1.002f860565c92p-58 },
    .{ .chi = 0x1.ef00007babcc4p-1, .clo = -0x1.540445d35e611p-55 },
    .{ .chi = 0x1.f0ffff57a8d02p-1, .clo = -0x1.ffb3139ef9105p-59 },
    .{ .chi = 0x1.f30001ee58ac7p-1, .clo = 0x1.a81acf2731155p-55 },
    .{ .chi = 0x1.f4ffff5823494p-1, .clo = 0x1.a3f41d4d7c743p-55 },
    .{ .chi = 0x1.f6ffffca94c6bp-1, .clo = -0x1.202f41c987875p-57 },
    .{ .chi = 0x1.f8fffe1f9c441p-1, .clo = 0x1.77dd1f477e74bp-56 },
    .{ .chi = 0x1.fafffd2e0e37ep-1, .clo = -0x1.f01199a7ca331p-57 },
    .{ .chi = 0x1.fd0001c77e49ep-1, .clo = 0x1.181ee4bceacb1p-56 },
    .{ .chi = 0x1.feffff7e0c331p-1, .clo = -0x1.e05370170875ap-57 },
    .{ .chi = 0x1.00ffff465606ep+0, .clo = -0x1.a7ead491c0adap-55 },
    .{ .chi = 0x1.02ffff3867a58p+0, .clo = -0x1.77f69c3fcb2ep-54 },
    .{ .chi = 0x1.04ffffdfc0d17p+0, .clo = 0x1.7bffe34cb945bp-54 },
    .{ .chi = 0x1.0700003cd4d82p+0, .clo = 0x1.20083c0e456cbp-55 },
    .{ .chi = 0x1.08ffff9f2cbe8p+0, .clo = -0x1.dffdfbe37751ap-57 },
    .{ .chi = 0x1.0b000010cda65p+0, .clo = -0x1.13f7faee626ebp-54 },
    .{ .chi = 0x1.0d00001a4d338p+0, .clo = 0x1.07dfa79489ff7p-55 },
    .{ .chi = 0x1.0effffadafdfdp+0, .clo = -0x1.7040570d66bcp-56 },
    .{ .chi = 0x1.110000bbafd96p+0, .clo = 0x1.e80d4846d0b62p-55 },
    .{ .chi = 0x1.12ffffae5f45dp+0, .clo = 0x1.dbffa64fd36efp-54 },
    .{ .chi = 0x1.150000dd59ad9p+0, .clo = 0x1.a0077701250aep-54 },
    .{ .chi = 0x1.170000f21559ap+0, .clo = 0x1.dfdf9e2e3deeep-55 },
    .{ .chi = 0x1.18ffffc275426p+0, .clo = 0x1.10030dc3b7273p-54 },
    .{ .chi = 0x1.1b000123d3c59p+0, .clo = 0x1.97f7980030188p-54 },
    .{ .chi = 0x1.1cffff8299eb7p+0, .clo = -0x1.5f932ab9f8c67p-57 },
    .{ .chi = 0x1.1effff48ad4p+0, .clo = 0x1.37fbf9da75bebp-54 },
    .{ .chi = 0x1.210000c8b86a4p+0, .clo = 0x1.f806b91fd5b22p-54 },
    .{ .chi = 0x1.2300003854303p+0, .clo = 0x1.3ffc2eb9fbf33p-54 },
    .{ .chi = 0x1.24fffffbcf684p+0, .clo = 0x1.601e77e2e2e72p-56 },
    .{ .chi = 0x1.26ffff52921d9p+0, .clo = 0x1.ffcbb767f0c61p-56 },
    .{ .chi = 0x1.2900014933a3cp+0, .clo = -0x1.202ca3c02412bp-56 },
    .{ .chi = 0x1.2b00014556313p+0, .clo = -0x1.2808233f21f02p-54 },
    .{ .chi = 0x1.2cfffebfe523bp+0, .clo = -0x1.8ff7e384fdcf2p-55 },
    .{ .chi = 0x1.2f0000bb8ad96p+0, .clo = -0x1.5ff51503041c5p-55 },
    .{ .chi = 0x1.30ffffb7ae2afp+0, .clo = -0x1.10071885e289dp-55 },
    .{ .chi = 0x1.32ffffeac5f7fp+0, .clo = -0x1.1ff5d3fb7b715p-54 },
    .{ .chi = 0x1.350000ca66756p+0, .clo = 0x1.57f82228b82bdp-54 },
    .{ .chi = 0x1.3700011fbf721p+0, .clo = 0x1.000bac40dd5ccp-55 },
    .{ .chi = 0x1.38ffff9592fb9p+0, .clo = -0x1.43f9d2db2a751p-54 },
    .{ .chi = 0x1.3b00004ddd242p+0, .clo = 0x1.57f6b707638e1p-55 },
    .{ .chi = 0x1.3cffff5b2c957p+0, .clo = 0x1.a023a10bf1231p-56 },
    .{ .chi = 0x1.3efffeab0b418p+0, .clo = 0x1.87f6d66b152bp-54 },
    .{ .chi = 0x1.410001532aff4p+0, .clo = 0x1.7f8375f198524p-57 },
    .{ .chi = 0x1.4300017478b29p+0, .clo = 0x1.301e672dc5143p-55 },
    .{ .chi = 0x1.44fffe795b463p+0, .clo = 0x1.9ff69b8b2895ap-55 },
    .{ .chi = 0x1.46fffe80475ep+0, .clo = -0x1.5c0b19bc2f254p-54 },
    .{ .chi = 0x1.48fffef6fc1e7p+0, .clo = 0x1.b4009f23a2a72p-54 },
    .{ .chi = 0x1.4afffe5bea704p+0, .clo = -0x1.4ffb7bf0d7d45p-54 },
    .{ .chi = 0x1.4d000171027dep+0, .clo = -0x1.9c06471dc6a3dp-54 },
    .{ .chi = 0x1.4f0000ff03ee2p+0, .clo = 0x1.77f890b85531cp-54 },
    .{ .chi = 0x1.5100012dc4bd1p+0, .clo = 0x1.004657166a436p-57 },
    .{ .chi = 0x1.530001605277ap+0, .clo = -0x1.6bfcece233209p-54 },
    .{ .chi = 0x1.54fffecdb704cp+0, .clo = -0x1.902720505a1d7p-55 },
    .{ .chi = 0x1.56fffef5f54a9p+0, .clo = 0x1.bbfe60ec96412p-54 },
    .{ .chi = 0x1.5900017e61012p+0, .clo = 0x1.87ec581afef9p-55 },
    .{ .chi = 0x1.5b00003c93e92p+0, .clo = -0x1.f41080abf0ccp-54 },
    .{ .chi = 0x1.5d0001d4919bcp+0, .clo = -0x1.8812afb254729p-54 },
    .{ .chi = 0x1.5efffe7b87a89p+0, .clo = -0x1.47eb780ed6904p-54 },
};

const log2_tab = [_]struct { invc: f64, logc: f64 }{
    .{ .invc = 0x1.724286bb1acf8p+0, .logc = -0x1.1095feecdb000p-1 },
    .{ .invc = 0x1.6e1f766d2cca1p+0, .logc = -0x1.08494bd76d000p-1 },
    .{ .invc = 0x1.6a13d0e30d48ap+0, .logc = -0x1.00143aee8f800p-1 },
    .{ .invc = 0x1.661ec32d06c85p+0, .logc = -0x1.efec5360b4000p-2 },
    .{ .invc = 0x1.623fa951198f8p+0, .logc = -0x1.dfdd91ab7e000p-2 },
    .{ .invc = 0x1.5e75ba4cf026cp+0, .logc = -0x1.cffae0cc79000p-2 },
    .{ .invc = 0x1.5ac055a214fb8p+0, .logc = -0x1.c043811fda000p-2 },
    .{ .invc = 0x1.571ed0f166e1ep+0, .logc = -0x1.b0b67323ae000p-2 },
    .{ .invc = 0x1.53909590bf835p+0, .logc = -0x1.a152f5a2db000p-2 },
    .{ .invc = 0x1.5014fed61adddp+0, .logc = -0x1.9217f5af86000p-2 },
    .{ .invc = 0x1.4cab88e487bd0p+0, .logc = -0x1.8304db0719000p-2 },
    .{ .invc = 0x1.49539b4334feep+0, .logc = -0x1.74189f9a9e000p-2 },
    .{ .invc = 0x1.460cbdfafd569p+0, .logc = -0x1.6552bb5199000p-2 },
    .{ .invc = 0x1.42d664ee4b953p+0, .logc = -0x1.56b23a29b1000p-2 },
    .{ .invc = 0x1.3fb01111dd8a6p+0, .logc = -0x1.483650f5fa000p-2 },
    .{ .invc = 0x1.3c995b70c5836p+0, .logc = -0x1.39de937f6a000p-2 },
    .{ .invc = 0x1.3991c4ab6fd4ap+0, .logc = -0x1.2baa1538d6000p-2 },
    .{ .invc = 0x1.3698e0ce099b5p+0, .logc = -0x1.1d98340ca4000p-2 },
    .{ .invc = 0x1.33ae48213e7b2p+0, .logc = -0x1.0fa853a40e000p-2 },
    .{ .invc = 0x1.30d191985bdb1p+0, .logc = -0x1.01d9c32e73000p-2 },
    .{ .invc = 0x1.2e025cab271d7p+0, .logc = -0x1.e857da2fa6000p-3 },
    .{ .invc = 0x1.2b404cf13cd82p+0, .logc = -0x1.cd3c8633d8000p-3 },
    .{ .invc = 0x1.288b02c7ccb50p+0, .logc = -0x1.b26034c14a000p-3 },
    .{ .invc = 0x1.25e2263944de5p+0, .logc = -0x1.97c1c2f4fe000p-3 },
    .{ .invc = 0x1.234563d8615b1p+0, .logc = -0x1.7d6023f800000p-3 },
    .{ .invc = 0x1.20b46e33eaf38p+0, .logc = -0x1.633a71a05e000p-3 },
    .{ .invc = 0x1.1e2eefdcda3ddp+0, .logc = -0x1.494f5e9570000p-3 },
    .{ .invc = 0x1.1bb4a580b3930p+0, .logc = -0x1.2f9e424e0a000p-3 },
    .{ .invc = 0x1.19453847f2200p+0, .logc = -0x1.162595afdc000p-3 },
    .{ .invc = 0x1.16e06c0d5d73cp+0, .logc = -0x1.f9c9a75bd8000p-4 },
    .{ .invc = 0x1.1485f47b7e4c2p+0, .logc = -0x1.c7b575bf9c000p-4 },
    .{ .invc = 0x1.12358ad0085d1p+0, .logc = -0x1.960c60ff48000p-4 },
    .{ .invc = 0x1.0fef00f532227p+0, .logc = -0x1.64ce247b60000p-4 },
    .{ .invc = 0x1.0db2077d03a8fp+0, .logc = -0x1.33f78b2014000p-4 },
    .{ .invc = 0x1.0b7e6d65980d9p+0, .logc = -0x1.0387d1a42c000p-4 },
    .{ .invc = 0x1.0953efe7b408dp+0, .logc = -0x1.a6f9208b50000p-5 },
    .{ .invc = 0x1.07325cac53b83p+0, .logc = -0x1.47a954f770000p-5 },
    .{ .invc = 0x1.05197e40d1b5cp+0, .logc = -0x1.d23a8c50c0000p-6 },
    .{ .invc = 0x1.03091c1208ea2p+0, .logc = -0x1.16a2629780000p-6 },
    .{ .invc = 0x1.0101025b37e21p+0, .logc = -0x1.720f8d8e80000p-8 },
    .{ .invc = 0x1.fc07ef9caa76bp-1, .logc = 0x1.6fe53b1500000p-7 },
    .{ .invc = 0x1.f4465d3f6f184p-1, .logc = 0x1.11ccce10f8000p-5 },
    .{ .invc = 0x1.ecc079f84107fp-1, .logc = 0x1.c4dfc8c8b8000p-5 },
    .{ .invc = 0x1.e573a99975ae8p-1, .logc = 0x1.3aa321e574000p-4 },
    .{ .invc = 0x1.de5d6f0bd3de6p-1, .logc = 0x1.918a0d08b8000p-4 },
    .{ .invc = 0x1.d77b681ff38b3p-1, .logc = 0x1.e72e9da044000p-4 },
    .{ .invc = 0x1.d0cb5724de943p-1, .logc = 0x1.1dcd2507f6000p-3 },
    .{ .invc = 0x1.ca4b2dc0e7563p-1, .logc = 0x1.476ab03dea000p-3 },
    .{ .invc = 0x1.c3f8ee8d6cb51p-1, .logc = 0x1.7074377e22000p-3 },
    .{ .invc = 0x1.bdd2b4f020c4cp-1, .logc = 0x1.98ede8ba94000p-3 },
    .{ .invc = 0x1.b7d6c006015cap-1, .logc = 0x1.c0db86ad2e000p-3 },
    .{ .invc = 0x1.b20366e2e338fp-1, .logc = 0x1.e840aafcee000p-3 },
    .{ .invc = 0x1.ac57026295039p-1, .logc = 0x1.0790ab4678000p-2 },
    .{ .invc = 0x1.a6d01bc2731ddp-1, .logc = 0x1.1ac056801c000p-2 },
    .{ .invc = 0x1.a16d3bc3ff18bp-1, .logc = 0x1.2db11d4fee000p-2 },
    .{ .invc = 0x1.9c2d14967feadp-1, .logc = 0x1.406464ec58000p-2 },
    .{ .invc = 0x1.970e4f47c9902p-1, .logc = 0x1.52dbe093af000p-2 },
    .{ .invc = 0x1.920fb3982bcf2p-1, .logc = 0x1.651902050d000p-2 },
    .{ .invc = 0x1.8d30187f759f1p-1, .logc = 0x1.771d2cdeaf000p-2 },
    .{ .invc = 0x1.886e5ebb9f66dp-1, .logc = 0x1.88e9c857d9000p-2 },
    .{ .invc = 0x1.83c97b658b994p-1, .logc = 0x1.9a80155e16000p-2 },
    .{ .invc = 0x1.7f405ffc61022p-1, .logc = 0x1.abe186ed3d000p-2 },
    .{ .invc = 0x1.7ad22181415cap-1, .logc = 0x1.bd0f2aea0e000p-2 },
    .{ .invc = 0x1.767dcf99eff8cp-1, .logc = 0x1.ce0a43dbf4000p-2 },
};

const log2_tab2 = [_]struct { chi: f64, clo: f64 }{
    .{ .chi = 0x1.6200012b90a8ep-1, .clo = 0x1.904ab0644b605p-55 },
    .{ .chi = 0x1.66000045734a6p-1, .clo = 0x1.1ff9bea62f7a9p-57 },
    .{ .chi = 0x1.69fffc325f2c5p-1, .clo = 0x1.27ecfcb3c90bap-55 },
    .{ .chi = 0x1.6e00038b95a04p-1, .clo = 0x1.8ff8856739326p-55 },
    .{ .chi = 0x1.71fffe09994e3p-1, .clo = 0x1.afd40275f82b1p-55 },
    .{ .chi = 0x1.7600015590e1p-1, .clo = -0x1.2fd75b4238341p-56 },
    .{ .chi = 0x1.7a00012655bd5p-1, .clo = 0x1.808e67c242b76p-56 },
    .{ .chi = 0x1.7e0003259e9a6p-1, .clo = -0x1.208e426f622b7p-57 },
    .{ .chi = 0x1.81fffedb4b2d2p-1, .clo = -0x1.402461ea5c92fp-55 },
    .{ .chi = 0x1.860002dfafcc3p-1, .clo = 0x1.df7f4a2f29a1fp-57 },
    .{ .chi = 0x1.89ffff78c6b5p-1, .clo = -0x1.e0453094995fdp-55 },
    .{ .chi = 0x1.8e00039671566p-1, .clo = -0x1.a04f3bec77b45p-55 },
    .{ .chi = 0x1.91fffe2bf1745p-1, .clo = -0x1.7fa34400e203cp-56 },
    .{ .chi = 0x1.95fffcc5c9fd1p-1, .clo = -0x1.6ff8005a0695dp-56 },
    .{ .chi = 0x1.9a0003bba4767p-1, .clo = 0x1.0f8c4c4ec7e03p-56 },
    .{ .chi = 0x1.9dfffe7b92da5p-1, .clo = 0x1.e7fd9478c4602p-55 },
    .{ .chi = 0x1.a1fffd72efdafp-1, .clo = -0x1.a0c554dcdae7ep-57 },
    .{ .chi = 0x1.a5fffde04ff95p-1, .clo = 0x1.67da98ce9b26bp-55 },
    .{ .chi = 0x1.a9fffca5e8d2bp-1, .clo = -0x1.284c9b54c13dep-55 },
    .{ .chi = 0x1.adfffddad03eap-1, .clo = 0x1.812c8ea602e3cp-58 },
    .{ .chi = 0x1.b1ffff10d3d4dp-1, .clo = -0x1.efaddad27789cp-55 },
    .{ .chi = 0x1.b5fffce21165ap-1, .clo = 0x1.3cb1719c61237p-58 },
    .{ .chi = 0x1.b9fffd950e674p-1, .clo = 0x1.3f7d94194cep-56 },
    .{ .chi = 0x1.be000139ca8afp-1, .clo = 0x1.50ac4215d9bcp-56 },
    .{ .chi = 0x1.c20005b46df99p-1, .clo = 0x1.beea653e9c1c9p-57 },
    .{ .chi = 0x1.c600040b9f7aep-1, .clo = -0x1.c079f274a70d6p-56 },
    .{ .chi = 0x1.ca0006255fd8ap-1, .clo = -0x1.a0b4076e84c1fp-56 },
    .{ .chi = 0x1.cdfffd94c095dp-1, .clo = 0x1.8f933f99ab5d7p-55 },
    .{ .chi = 0x1.d1ffff975d6cfp-1, .clo = -0x1.82c08665fe1bep-58 },
    .{ .chi = 0x1.d5fffa2561c93p-1, .clo = -0x1.b04289bd295f3p-56 },
    .{ .chi = 0x1.d9fff9d228b0cp-1, .clo = 0x1.70251340fa236p-55 },
    .{ .chi = 0x1.de00065bc7e16p-1, .clo = -0x1.5011e16a4d80cp-56 },
    .{ .chi = 0x1.e200002f64791p-1, .clo = 0x1.9802f09ef62ep-55 },
    .{ .chi = 0x1.e600057d7a6d8p-1, .clo = -0x1.e0b75580cf7fap-56 },
    .{ .chi = 0x1.ea00027edc00cp-1, .clo = -0x1.c848309459811p-55 },
    .{ .chi = 0x1.ee0006cf5cb7cp-1, .clo = -0x1.f8027951576f4p-55 },
    .{ .chi = 0x1.f2000782b7dccp-1, .clo = -0x1.f81d97274538fp-55 },
    .{ .chi = 0x1.f6000260c450ap-1, .clo = -0x1.071002727ffdcp-59 },
    .{ .chi = 0x1.f9fffe88cd533p-1, .clo = -0x1.81bdce1fda8bp-58 },
    .{ .chi = 0x1.fdfffd50f8689p-1, .clo = 0x1.7f91acb918e6ep-55 },
    .{ .chi = 0x1.0200004292367p+0, .clo = 0x1.b7ff365324681p-54 },
    .{ .chi = 0x1.05fffe3e3d668p+0, .clo = 0x1.6fa08ddae957bp-55 },
    .{ .chi = 0x1.0a0000a85a757p+0, .clo = -0x1.7e2de80d3fb91p-58 },
    .{ .chi = 0x1.0e0001a5f3fccp+0, .clo = -0x1.1823305c5f014p-54 },
    .{ .chi = 0x1.11ffff8afbaf5p+0, .clo = -0x1.bfabb6680bac2p-55 },
    .{ .chi = 0x1.15fffe54d91adp+0, .clo = -0x1.d7f121737e7efp-54 },
    .{ .chi = 0x1.1a00011ac36e1p+0, .clo = 0x1.c000a0516f5ffp-54 },
    .{ .chi = 0x1.1e00019c84248p+0, .clo = -0x1.082fbe4da5dap-54 },
    .{ .chi = 0x1.220000ffe5e6ep+0, .clo = -0x1.8fdd04c9cfb43p-55 },
    .{ .chi = 0x1.26000269fd891p+0, .clo = 0x1.cfe2a7994d182p-55 },
    .{ .chi = 0x1.2a00029a6e6dap+0, .clo = -0x1.00273715e8bc5p-56 },
    .{ .chi = 0x1.2dfffe0293e39p+0, .clo = 0x1.b7c39dab2a6f9p-54 },
    .{ .chi = 0x1.31ffff7dcf082p+0, .clo = 0x1.df1336edc5254p-56 },
    .{ .chi = 0x1.35ffff05a8b6p+0, .clo = -0x1.e03564ccd31ebp-54 },
    .{ .chi = 0x1.3a0002e0eaeccp+0, .clo = 0x1.5f0e74bd3a477p-56 },
    .{ .chi = 0x1.3e000043bb236p+0, .clo = 0x1.c7dcb149d8833p-54 },
    .{ .chi = 0x1.4200002d187ffp+0, .clo = 0x1.e08afcf2d3d28p-56 },
    .{ .chi = 0x1.460000d387cb1p+0, .clo = 0x1.20837856599a6p-55 },
    .{ .chi = 0x1.4a00004569f89p+0, .clo = -0x1.9fa5c904fbcd2p-55 },
    .{ .chi = 0x1.4e000043543f3p+0, .clo = -0x1.81125ed175329p-56 },
    .{ .chi = 0x1.51fffcc027f0fp+0, .clo = 0x1.883d8847754dcp-54 },
    .{ .chi = 0x1.55ffffd87b36fp+0, .clo = -0x1.709e731d02807p-55 },
    .{ .chi = 0x1.59ffff21df7bap+0, .clo = 0x1.7f79f68727b02p-55 },
    .{ .chi = 0x1.5dfffebfc3481p+0, .clo = -0x1.180902e30e93ep-54 },
};

test "exp and pow match glibc on the reference's machine" {
    // Bits from reference Lua 5.5.1 on glibc 2.44 (`string.format("%a")`),
    // on a CPU with FMA. Without FMA glibc rounds a few of them differently,
    // and so does this file.
    if (!has_fma) return error.SkipZigTest;
    const cases = [_]struct { f: enum { exp, pow }, x: f64, y: f64 = 0, want: f64 }{
        .{ .f = .exp, .x = 1, .want = 0x1.5bf0a8b145769p+1 },
        .{ .f = .exp, .x = -0x1.0dce0e1e56c11p+7, .want = 0x1.4c6dd06d95fe2p-195 },
        .{ .f = .pow, .x = 0x1.0dce0e1e56c11p+7, .y = 0x1.d4c7fd53b908p+1, .want = 0x1.e25d3af9a1209p+25 },
        .{ .f = .exp, .x = -0x1.3d6f041353306p+3, .want = 0x1.9ca4ababa2246p-15 },
        .{ .f = .pow, .x = 0x1.3d6f041353306p+3, .y = 0x1.bd61adc27cd42p+2, .want = 0x1.069a8f6aa2f44p+23 },
        .{ .f = .exp, .x = 0x1.635eeaaed99cdp+17, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1.635eeaaed99cdp+17, .y = 0x1.716c984e5ee4ap+1, .want = 0x1.58d8cfc2cb81ap+50 },
        .{ .f = .exp, .x = 0x1.d56f9957b4738p-1, .want = 0x1.402f39e9d0a8cp+1 },
        .{ .f = .pow, .x = 0x1.d56f9957b4738p-1, .y = 0x1.724172b2d6dc9p+2, .want = 0x1.35e305b6c2fbfp-1 },
        .{ .f = .exp, .x = 0x1.e1a5193f1a1a9p+19, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1.e1a5193f1a1a9p+19, .y = 0x1.702b316dcde07p-1, .want = 0x1.3f2bd47293e08p+14 },
        .{ .f = .exp, .x = 0x1.cedf9a1c97b16p+19, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1.cedf9a1c97b16p+19, .y = -0x1.26264f4780bfap+1, .want = 0x1.4ba7e099339bbp-46 },
        .{ .f = .exp, .x = 0x1.4ce110255181ap+2, .want = 0x1.6afe3e859905ap+7 },
        .{ .f = .pow, .x = 0x1.4ce110255181ap+2, .y = 0x1.f92be9a236e38p+0, .want = 0x1.9e388d8fb10dfp+4 },
        .{ .f = .exp, .x = 0x1.3a2af8a359abap+9, .want = 0x1.693da31d3fa4fp+906 },
        .{ .f = .pow, .x = 0x1.3a2af8a359abap+9, .y = 0x1.ec8568872296dp+1, .want = 0x1.b3a4e87eae73ep+35 },
        .{ .f = .exp, .x = 0x1.5b6af516dbdap+8, .want = 0x1.29bf16a6c9055p+501 },
        .{ .f = .pow, .x = 0x1.5b6af516dbdap+8, .y = 0x1.0666c344ba673p+2, .want = 0x1.85bc430a983f9p+34 },
        .{ .f = .exp, .x = 0x1.b28f06dc562cp-5, .want = 0x1.0df2545bda329p+0 },
        .{ .f = .pow, .x = 0x1.b28f06dc562cp-5, .y = 0x1.093b4b6fb661p+1, .want = 0x1.2a6ed351ab2d7p-9 },
        .{ .f = .pow, .x = 0x1p+1, .y = 0x1p-1, .want = 0x1.6a09e667f3bcdp+0 },
        .{
            .f = .pow,
            .x = -0x1p+3,
            .y = 0x1.5555555555555p-2,
            .want = @as(f64, @bitCast(@as(u64, 0xfff8000000000000))),
        },
        .{ .f = .pow, .x = -0x1p+1, .y = 0x1.8p+1, .want = -0x1p+3 },
        .{ .f = .pow, .x = -0x1p+1, .y = 0x1p+1, .want = 0x1p+2 },
        .{ .f = .pow, .x = 0x0p+0, .y = -0x1p+0, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = -0x0p+0, .y = -0x1p+0, .want = -std.math.inf(f64) },
        .{ .f = .pow, .x = -0x0p+0, .y = -0x1.8p+1, .want = -std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1p+1, .y = 0x1p+10, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1p+1, .y = -0x1.0ccp+10, .want = 0x0p+0 },
        .{ .f = .pow, .x = 0x1p+1, .y = -0x1.0c8p+10, .want = 0x0.0000000000001p-1022 },
        .{ .f = .pow, .x = 0x1.000001ad7f29bp+0, .y = 0x1.7e43c8800759cp+996, .want = std.math.inf(f64) },
        .{ .f = .pow, .x = 0x1p-1, .y = 0x1.615e91d8f359dp-233, .want = 0x1p+0 },
        .{ .f = .pow, .x = 0x1.4p+3, .y = -0x1.8p+1, .want = 0x1.0624dd2f1a9fcp-10 },
        .{ .f = .pow, .x = std.math.inf(f64), .y = -0x1p+0, .want = 0x0p+0 },
        .{ .f = .pow, .x = -std.math.inf(f64), .y = 0x1.8p+1, .want = -std.math.inf(f64) },
        .{ .f = .pow, .x = 0x0.012688b70e62bp-1022, .y = 0x1p-1, .want = 0x1.1297872d9cbaep-515 },
        .{ .f = .exp, .x = 0x1.62d999999999ap+9, .want = 0x1.d75ae7a50ee14p+1023 },
        .{ .f = .exp, .x = 0x1.62e6666666666p+9, .want = std.math.inf(f64) },
        .{ .f = .exp, .x = -0x1.748p+9, .want = 0x0.0000000000001p-1022 },
        .{ .f = .exp, .x = -0x1.749999999999ap+9, .want = 0x0p+0 },
        .{ .f = .exp, .x = -0x1.624p+9, .want = 0x0.e6cf6d08897acp-1022 },
        .{ .f = .exp, .x = 0x1.56e1fc2f8f359p-997, .want = 0x1p+0 },
        .{ .f = .exp, .x = -0x1.79ca10c924223p-67, .want = 0x1p+0 },
    };
    for (cases) |c| {
        const got = switch (c.f) {
            .exp => exp(c.x),
            .pow => pow(c.x, c.y),
        };
        try std.testing.expectEqual(@as(u64, @bitCast(c.want)), @as(u64, @bitCast(got)));
    }
}

test "log, log2, and log10 match glibc on the reference's machine" {
    // Bits from reference Lua 5.5.1 on glibc 2.44: `math.log(x)`,
    // `math.log(x, 2)`, and `math.log(x, 10)` in `%a`, on a CPU with FMA.
    if (!has_fma) return error.SkipZigTest;
    const cases = [_][4]f64{
        .{ 0x1.fffffdf0c2475p-1, -0x1.079edcdfbbe6p-24, -0x1.7c52f6575f9d9p-24, -0x1.c9f4b03da7053p-26 },
        .{ 0x1.7f577037739e7p+14, 0x1.43732cd686728p+3, 0x1.d2a3baeb8875bp+3, 0x1.18f1ec91f3678p+2 },
        .{ 0x1.fffff3166f92bp-1, -0x1.9d3212dfd52a3p-22, -0x1.2a0ec04eb5dd2p-21, -0x1.66e5aade2f6dbp-23 },
        .{ 0x1.e60efddb237a1p+19, 0x1.b9f3496d5d71bp+3, 0x1.3eccbe77d6a98p+4, 0x1.7fdf893157b1ap+2 },
        .{ 0x1.24f5043e5ac44p+51, 0x1.1be201c44afbbp+5, 0x1.998e6dea6bf2p+5, 0x1.ed27ae4261504p+3 },
        .{ 0x1.899b539c89aa7p+19, 0x1.b332f6fbe5782p+3, 0x1.39ee05f01ed96p+4, 0x1.7a02559ee757p+2 },
        .{ 0x1.d5fae6d648db4p+455, 0x1.3bfd4e903693ap+8, 0x1.c7e05f6882af8p+8, 0x1.1277089a952f5p+7 },
        .{ 0x1.f9a22ae7367edp-1, -0x1.9a03398c88a3bp-7, -0x1.27c2f64235cf8p-6, -0x1.6421e60f10799p-8 },
        .{ 0x1.6e886607844b4p+224, 0x1.373f6d128fa76p+7, 0x1.c1091ce359aecp+7, 0x1.0e58ab8d1e22bp+6 },
        .{ 0x1.cf0fedbce4a18p-1, -0x1.9b7f4aed19278p-4, -0x1.28d51f7afd37p-3, -0x1.656c057ca5021p-5 },
        .{ 0x1.ef3e2e1b88d38p-1, -0x1.1099723897d4cp-5, -0x1.89471dfbdd597p-5, -0x1.d98dbc9cac615p-7 },
        .{ 0x1p+0, 0x0p+0, 0x0p+0, 0x0p+0 },
        .{ 0x0.0000000000001p-1022, -0x1.74385446d71c3p+9, -0x1.0c8p+10, -0x1.434e6420f4374p+8 },
        .{ 0x0.03p-1022, -0x1.646be6e3b5ac5p+9, -0x1.011a8ff971811p+10, -0x1.3595723b2d54p+8 },
        .{ 0x1.1ccf385ebc8ap+1023, 0x1.62991d5d62a5ep+9, 0x1.ff93b176658a4p+9, 0x1.34p+8 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(@as(u64, @bitCast(c[1])), @as(u64, @bitCast(log(c[0]))));
        try std.testing.expectEqual(@as(u64, @bitCast(c[2])), @as(u64, @bitCast(log2(c[0]))));
        try std.testing.expectEqual(@as(u64, @bitCast(c[3])), @as(u64, @bitCast(log10(c[0]))));
    }
    try std.testing.expectEqual(-std.math.inf(f64), log(0.0));
    try std.testing.expectEqual(-std.math.inf(f64), log2(-0.0));
    try std.testing.expectEqual(-std.math.inf(f64), log10(0.0));
    // A negative number: x86's default NaN from log and log2, the
    // wrapper's positive one from log10.
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqual(@as(u64, 0xfff8000000000000), @as(u64, @bitCast(log(-1.0))));
        try std.testing.expectEqual(@as(u64, 0xfff8000000000000), @as(u64, @bitCast(log2(-1.0))));
    }
    try std.testing.expectEqual(@as(u64, 0x7ff8000000000000), @as(u64, @bitCast(log10(-1.0))));
}
