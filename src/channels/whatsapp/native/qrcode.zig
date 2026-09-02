const std = @import("std");

// ISO/IEC 18004 QR Code (Model 2), byte mode, error-correction level L.
// Versions 1..25. Heap allocation is only the output Matrix / render buffers.

const max_version: u8 = 25;
const max_size: usize = 21 + 4 * (max_version - 1);
const max_modules: usize = max_size * max_size;
const max_total_cw: usize = 1588;
const max_data_cw: usize = 1276;
const max_blocks: usize = 12;
const max_dc: usize = 128;
const max_ec: usize = 32;

const gf_tables = buildGf();
const gf_exp = gf_tables.exp;
const gf_log = gf_tables.log;

fn buildGf() struct { exp: [512]u8, log: [256]u8 } {
    var exp: [512]u8 = [_]u8{0} ** 512;
    var logt: [256]u8 = [_]u8{0} ** 256;
    var x: u16 = 1;
    for (0..255) |i| {
        exp[i] = @intCast(x);
        logt[@as(u8, @intCast(x))] = @intCast(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (255..512) |i| exp[i] = exp[i - 255];
    return .{ .exp = exp, .log = logt };
}

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + @as(usize, gf_log[b])];
}

/// RS block layout for level L, versions 1..25.
/// Fields: g1_blocks, g1_total, g1_data, g2_blocks, g2_total, g2_data.
const rs_l: [25][6]u8 = .{
    .{ 1, 26, 19, 0, 0, 0 },
    .{ 1, 44, 34, 0, 0, 0 },
    .{ 1, 70, 55, 0, 0, 0 },
    .{ 1, 100, 80, 0, 0, 0 },
    .{ 1, 134, 108, 0, 0, 0 },
    .{ 2, 86, 68, 0, 0, 0 },
    .{ 2, 98, 78, 0, 0, 0 },
    .{ 2, 121, 97, 0, 0, 0 },
    .{ 2, 146, 116, 0, 0, 0 },
    .{ 2, 86, 68, 2, 87, 69 },
    .{ 4, 101, 81, 0, 0, 0 },
    .{ 2, 116, 92, 2, 117, 93 },
    .{ 4, 133, 107, 0, 0, 0 },
    .{ 3, 145, 115, 1, 146, 116 },
    .{ 5, 109, 87, 1, 110, 88 },
    .{ 5, 122, 98, 1, 123, 99 },
    .{ 1, 135, 107, 5, 136, 108 },
    .{ 5, 150, 120, 1, 151, 121 },
    .{ 3, 141, 113, 4, 142, 114 },
    .{ 3, 135, 107, 5, 136, 108 },
    .{ 4, 144, 116, 4, 145, 117 },
    .{ 2, 139, 111, 7, 140, 112 },
    .{ 4, 151, 121, 5, 152, 122 },
    .{ 6, 147, 117, 4, 148, 118 },
    .{ 8, 132, 106, 4, 133, 107 },
};

fn dataCodewords(version: u8) u16 {
    const t = rs_l[version - 1];
    return @as(u16, t[0]) * t[2] + @as(u16, t[3]) * t[5];
}

fn countBits(version: u8) u16 {
    return if (version < 10) 8 else 16;
}

fn bitsNeeded(n: usize, version: u8) usize {
    return 4 + @as(usize, countBits(version)) + 8 * n;
}

fn selectVersion(n: usize) ?u8 {
    var v: u8 = 1;
    while (v <= max_version) : (v += 1) {
        if (bitsNeeded(n, v) <= @as(usize, dataCodewords(v)) * 8) return v;
    }
    return null;
}

fn alignmentCenters(version: u8) []const u8 {
    return switch (version) {
        1 => &.{},
        2 => &.{ 6, 18 },
        3 => &.{ 6, 22 },
        4 => &.{ 6, 26 },
        5 => &.{ 6, 30 },
        6 => &.{ 6, 34 },
        7 => &.{ 6, 22, 38 },
        8 => &.{ 6, 24, 42 },
        9 => &.{ 6, 26, 46 },
        10 => &.{ 6, 28, 50 },
        11 => &.{ 6, 30, 54 },
        12 => &.{ 6, 32, 58 },
        13 => &.{ 6, 34, 62 },
        14 => &.{ 6, 26, 46, 66 },
        15 => &.{ 6, 26, 48, 70 },
        16 => &.{ 6, 26, 50, 74 },
        17 => &.{ 6, 30, 54, 78 },
        18 => &.{ 6, 30, 56, 82 },
        19 => &.{ 6, 30, 58, 86 },
        20 => &.{ 6, 34, 62, 90 },
        21 => &.{ 6, 28, 50, 72, 94 },
        22 => &.{ 6, 26, 50, 74, 98 },
        23 => &.{ 6, 30, 54, 78, 102 },
        24 => &.{ 6, 28, 54, 80, 106 },
        25 => &.{ 6, 32, 58, 84, 110 },
        else => &.{},
    };
}

fn bitLen(x: u32) u8 {
    var n: u8 = 0;
    var v = x;
    while (v != 0) {
        v >>= 1;
        n += 1;
    }
    return n;
}

fn formatBch(data: u5) u16 {
    var d: u32 = @as(u32, data) << 10;
    const g: u32 = 0x537;
    while (bitLen(d) >= 11) {
        d ^= g << @as(u5, @intCast(bitLen(d) - 11));
    }
    return @intCast(((@as(u32, data) << 10) | d) ^ 0x5412);
}

fn formatBitsL(mask: u8) u16 {
    const data: u5 = @intCast((@as(u8, 0b01) << 3) | mask);
    return formatBch(data);
}

fn versionBch(version: u8) u32 {
    var d: u32 = @as(u32, version) << 12;
    const g: u32 = 0x1F25;
    while (bitLen(d) >= 13) {
        d ^= g << @as(u5, @intCast(bitLen(d) - 13));
    }
    return (@as(u32, version) << 12) | d;
}

fn buildGenerator(nsym: usize, gen: *[31]u8) void {
    @memset(gen, 0);
    gen[0] = 1;
    var degree: usize = 0;
    for (0..nsym) |i| {
        const coef = gf_exp[i];
        gen[degree + 1] = gfMul(gen[degree], coef);
        var k = degree;
        while (k >= 1) : (k -= 1) {
            gen[k] = gen[k] ^ gfMul(coef, gen[k - 1]);
        }
        degree += 1;
    }
}

fn rsEncode(data: []const u8, nsym: usize, gen: []const u8, ec: []u8) void {
    @memset(ec, 0);
    for (data) |b| {
        const factor = b ^ ec[0];
        var i: usize = 0;
        while (i + 1 < nsym) : (i += 1) {
            ec[i] = ec[i + 1] ^ gfMul(factor, gen[i + 1]);
        }
        ec[nsym - 1] = gfMul(factor, gen[nsym]);
    }
}

/// Remainder of `poly` (high degree first) modulo `gen` (degree nsym, gen[0]=1).
fn polyMod(poly: []const u8, gen: []const u8, nsym: usize, rem: []u8) void {
    var buf: [max_total_cw + max_ec]u8 = undefined;
    const n = poly.len;
    @memcpy(buf[0..n], poly);
    if (n <= nsym) {
        @memset(rem, 0);
        if (n > 0) @memcpy(rem[nsym - n .. nsym], buf[0..n]);
        return;
    }
    var i: usize = 0;
    while (i + nsym < n) : (i += 1) {
        const factor = buf[i];
        if (factor == 0) continue;
        for (0..nsym + 1) |j| {
            buf[i + j] ^= gfMul(factor, gen[j]);
        }
    }
    @memcpy(rem[0..nsym], buf[n - nsym .. n]);
}

const BitWriter = struct {
    bytes: []u8,
    bit_len: usize = 0,

    fn put(self: *BitWriter, value: u32, nbits: u16) void {
        var n = nbits;
        while (n > 0) {
            n -= 1;
            const bit: u8 = @intCast((value >> @intCast(n)) & 1);
            const bi = self.bit_len / 8;
            const sh: u3 = @intCast(7 - (self.bit_len % 8));
            self.bytes[bi] |= bit << sh;
            self.bit_len += 1;
        }
    }
};

fn maskApplies(mask: u8, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x * y) % 3 + (x + y) % 2) % 2 == 0,
        else => unreachable,
    };
}

fn finderDark(dx: i32, dy: i32) bool {
    if (dx < 0 or dy < 0 or dx > 6 or dy > 6) return false;
    if (dx == 0 or dx == 6 or dy == 0 or dy == 6) return true;
    return dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4;
}

fn setCell(modules: []u8, reserved: []u8, size: usize, x: usize, y: usize, dark: bool) void {
    const i = y * size + x;
    modules[i] = if (dark) 1 else 0;
    reserved[i] = 1;
}

fn placeFinder(modules: []u8, reserved: []u8, size: usize, left: usize, top: usize) void {
    var dy: i32 = -1;
    while (dy <= 7) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 7) : (dx += 1) {
            const x = @as(i32, @intCast(left)) + dx;
            const y = @as(i32, @intCast(top)) + dy;
            if (x < 0 or y < 0 or x >= @as(i32, @intCast(size)) or y >= @as(i32, @intCast(size))) continue;
            setCell(modules, reserved, size, @intCast(x), @intCast(y), finderDark(dx, dy));
        }
    }
}

fn placeAlignment(modules: []u8, reserved: []u8, size: usize, cx: usize, cy: usize) void {
    if (reserved[cy * size + cx] != 0) return;
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const dark = (@abs(dx) == 2) or (@abs(dy) == 2) or (dx == 0 and dy == 0);
            const x: usize = @intCast(@as(i32, @intCast(cx)) + dx);
            const y: usize = @intCast(@as(i32, @intCast(cy)) + dy);
            setCell(modules, reserved, size, x, y, dark);
        }
    }
}

fn reserveFormat(reserved: []u8, size: usize) void {
    for (0..9) |i| {
        if (i == 6) continue;
        reserved[8 * size + i] = 1;
        reserved[i * size + 8] = 1;
    }
    for (0..8) |i| {
        reserved[8 * size + (size - 1 - i)] = 1;
        reserved[(size - 1 - i) * size + 8] = 1;
    }
}

fn reserveVersion(reserved: []u8, size: usize) void {
    for (0..6) |a| {
        for (0..3) |b| {
            reserved[a * size + (size - 11 + b)] = 1;
            reserved[(size - 11 + b) * size + a] = 1;
        }
    }
}

fn placeFormat(modules: []u8, size: usize, bits: u16) void {
    var v: u4 = 0;
    while (v < 15) : (v += 1) {
        const dark: u8 = @intCast((bits >> v) & 1);
        const y: usize = if (v < 6) v else if (v < 8) @as(usize, v) + 1 else size - 15 + @as(usize, v);
        modules[y * size + 8] = dark;
    }
    var h: u4 = 0;
    while (h < 15) : (h += 1) {
        const dark: u8 = @intCast((bits >> h) & 1);
        const x: usize = if (h < 8)
            size - @as(usize, h) - 1
        else if (h < 9)
            7
        else
            14 - @as(usize, h);
        modules[8 * size + x] = dark;
    }
    modules[(size - 8) * size + 8] = 1;
}

fn placeVersionInfo(modules: []u8, size: usize, version: u8) void {
    const bits = versionBch(version);
    var i: u5 = 0;
    while (i < 18) : (i += 1) {
        const dark: u8 = @intCast((bits >> i) & 1);
        const r1 = @as(usize, i) / 3;
        const c1 = size - 11 + @as(usize, i) % 3;
        modules[r1 * size + c1] = dark;
        const r2 = size - 11 + @as(usize, i) % 3;
        const c2 = @as(usize, i) / 3;
        modules[r2 * size + c2] = dark;
    }
}

fn placeData(modules: []u8, reserved: []const u8, size: usize, codewords: []const u8) void {
    var inc: i32 = -1;
    var row: i32 = @intCast(size - 1);
    var bit_index: i32 = 7;
    var byte_index: usize = 0;
    var col: i32 = @intCast(size - 1);
    while (col > 0) {
        if (col == 6) col -= 1;
        while (true) {
            var c: i32 = 0;
            while (c < 2) : (c += 1) {
                const x: usize = @intCast(col - c);
                const y: usize = @intCast(row);
                const i = y * size + x;
                if (reserved[i] != 0) continue;
                var dark: u8 = 0;
                if (byte_index < codewords.len) {
                    dark = @intCast((codewords[byte_index] >> @intCast(bit_index)) & 1);
                }
                modules[i] = dark;
                bit_index -= 1;
                if (bit_index < 0) {
                    byte_index += 1;
                    bit_index = 7;
                }
            }
            row += inc;
            if (row < 0 or row >= @as(i32, @intCast(size))) {
                row -= inc;
                inc = -inc;
                break;
            }
        }
        col -= 2;
    }
}

fn applyMask(dst: []u8, src: []const u8, reserved: []const u8, size: usize, mask: u8) void {
    const n = size * size;
    @memcpy(dst[0..n], src[0..n]);
    for (0..n) |i| {
        if (reserved[i] != 0) continue;
        const x = i % size;
        const y = i / size;
        if (maskApplies(mask, x, y)) dst[i] ^= 1;
    }
}

fn calcN1N3(run_length: []const i32, length: usize) u32 {
    var demerit: u32 = 0;
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const rl = run_length[i];
        if (rl >= 5) demerit += 3 + @as(u32, @intCast(rl - 5));
        if ((i & 1) == 1 and i >= 3 and i + 2 < length and @rem(rl, 3) == 0) {
            const fact = @divTrunc(rl, 3);
            if (run_length[i - 2] == fact and
                run_length[i - 1] == fact and
                run_length[i + 1] == fact and
                run_length[i + 2] == fact)
            {
                if (i == 3 or run_length[i - 3] >= 4 * fact) {
                    demerit += 40;
                } else if (i + 4 >= length or run_length[i + 3] >= 4 * fact) {
                    demerit += 40;
                }
            }
        }
    }
    return demerit;
}

fn runLengthH(frame: []const u8, size: usize, y: usize, run: *[max_size + 1]i32) usize {
    const row = frame[y * size ..][0..size];
    var head: usize = 0;
    if (row[0] == 1) {
        run[0] = -1;
        head = 1;
    }
    run[head] = 1;
    var prev = row[0];
    var i: usize = 1;
    while (i < size) : (i += 1) {
        if (row[i] != prev) {
            head += 1;
            run[head] = 1;
            prev = row[i];
        } else {
            run[head] += 1;
        }
    }
    return head + 1;
}

fn runLengthV(frame: []const u8, size: usize, x: usize, run: *[max_size + 1]i32) usize {
    var head: usize = 0;
    if (frame[x] == 1) {
        run[0] = -1;
        head = 1;
    }
    run[head] = 1;
    var prev = frame[x];
    var y: usize = 1;
    while (y < size) : (y += 1) {
        const v = frame[y * size + x];
        if (v != prev) {
            head += 1;
            run[head] = 1;
            prev = v;
        } else {
            run[head] += 1;
        }
    }
    return head + 1;
}

fn penaltyScore(frame: []const u8, size: usize) u32 {
    const n = size * size;
    var darks: u32 = 0;
    for (frame[0..n]) |m| darks += m;

    const w2: u32 = @intCast(n);
    const bratio = (200 * darks + w2) / w2 / 2;
    var demerit: u32 = (@abs(@as(i32, @intCast(bratio)) - 50) / 5) * 10;

    var y: usize = 0;
    while (y + 1 < size) : (y += 1) {
        var x: usize = 0;
        while (x + 1 < size) : (x += 1) {
            const a = frame[y * size + x];
            const b = frame[y * size + x + 1];
            const c = frame[(y + 1) * size + x];
            const d = frame[(y + 1) * size + x + 1];
            if (a == b and a == c and a == d) demerit += 3;
        }
    }

    var run: [max_size + 1]i32 = undefined;
    var row_i: usize = 0;
    while (row_i < size) : (row_i += 1) {
        const len = runLengthH(frame, size, row_i, &run);
        demerit += calcN1N3(run[0..], len);
    }
    var col_i: usize = 0;
    while (col_i < size) : (col_i += 1) {
        const len = runLengthV(frame, size, col_i, &run);
        demerit += calcN1N3(run[0..], len);
    }
    return demerit;
}

fn buildDataCodewords(text: []const u8, version: u8, out: []u8) usize {
    const dcw = dataCodewords(version);
    @memset(out[0..dcw], 0);
    var bw = BitWriter{ .bytes = out[0..dcw] };
    bw.put(0b0100, 4);
    bw.put(@intCast(text.len), countBits(version));
    for (text) |ch| bw.put(ch, 8);
    const cap = @as(usize, dcw) * 8;
    if (bw.bit_len + 4 <= cap) bw.put(0, 4);
    while (bw.bit_len % 8 != 0) bw.put(0, 1);
    var pad0 = true;
    while (bw.bit_len < cap) {
        bw.put(if (pad0) 0xEC else 0x11, 8);
        pad0 = !pad0;
    }
    return dcw;
}

fn interleave(version: u8, data: []const u8, out: []u8) usize {
    const spec = rs_l[version - 1];
    const g1n = spec[0];
    const g1_total = spec[1];
    const g1_data = spec[2];
    const g2n = spec[3];
    const g2_data = spec[5];
    const nsym: usize = g1_total - g1_data;

    var gen_buf: [31]u8 = undefined;
    buildGenerator(nsym, &gen_buf);
    const gen = gen_buf[0 .. nsym + 1];

    var dc: [max_blocks][max_dc]u8 = undefined;
    var ec: [max_blocks][max_ec]u8 = undefined;
    var dc_len: [max_blocks]u8 = undefined;
    var nblocks: usize = 0;
    var off: usize = 0;

    var b: u8 = 0;
    while (b < g1n) : (b += 1) {
        const k = g1_data;
        @memcpy(dc[nblocks][0..k], data[off..][0..k]);
        rsEncode(dc[nblocks][0..k], nsym, gen, ec[nblocks][0..nsym]);
        dc_len[nblocks] = k;
        off += k;
        nblocks += 1;
    }
    b = 0;
    while (b < g2n) : (b += 1) {
        const k = g2_data;
        @memcpy(dc[nblocks][0..k], data[off..][0..k]);
        rsEncode(dc[nblocks][0..k], nsym, gen, ec[nblocks][0..nsym]);
        dc_len[nblocks] = k;
        off += k;
        nblocks += 1;
    }

    var maxd: usize = g1_data;
    if (g2n > 0) maxd = @max(maxd, @as(usize, g2_data));
    var idx: usize = 0;
    var i: usize = 0;
    while (i < maxd) : (i += 1) {
        var bi: usize = 0;
        while (bi < nblocks) : (bi += 1) {
            if (i < dc_len[bi]) {
                out[idx] = dc[bi][i];
                idx += 1;
            }
        }
    }
    i = 0;
    while (i < nsym) : (i += 1) {
        var bi: usize = 0;
        while (bi < nblocks) : (bi += 1) {
            out[idx] = ec[bi][i];
            idx += 1;
        }
    }
    return idx;
}

pub const Matrix = struct {
    size: usize,
    modules: []u8,
    version: u8 = 0,
    mask: u8 = 0,

    pub fn get(self: Matrix, x: usize, y: usize) bool {
        return self.modules[y * self.size + x] != 0;
    }

    /// Memory: frees `modules`.
    pub fn deinit(self: *Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        self.modules = &.{};
        self.size = 0;
    }
};

/// Memory: caller deinit.
pub fn encode(allocator: std.mem.Allocator, text: []const u8) !Matrix {
    const version = selectVersion(text.len) orelse return error.TooLong;
    const size: usize = 21 + 4 * (@as(usize, version) - 1);

    var data_buf: [max_data_cw]u8 = undefined;
    const dcw = buildDataCodewords(text, version, &data_buf);

    var interleaved: [max_total_cw]u8 = undefined;
    const n_cw = interleave(version, data_buf[0..dcw], &interleaved);

    const modules = try allocator.alloc(u8, size * size);
    errdefer allocator.free(modules);
    @memset(modules, 0);

    var reserved_buf: [max_modules]u8 = undefined;
    const reserved = reserved_buf[0 .. size * size];
    @memset(reserved, 0);

    placeFinder(modules, reserved, size, 0, 0);
    placeFinder(modules, reserved, size, size - 7, 0);
    placeFinder(modules, reserved, size, 0, size - 7);

    const pos = alignmentCenters(version);
    for (pos) |cy| {
        for (pos) |cx| {
            placeAlignment(modules, reserved, size, cx, cy);
        }
    }

    var i: usize = 8;
    while (i < size - 8) : (i += 1) {
        if (reserved[i * size + 6] == 0) setCell(modules, reserved, size, 6, i, i % 2 == 0);
        if (reserved[6 * size + i] == 0) setCell(modules, reserved, size, i, 6, i % 2 == 0);
    }

    const dark_y = 4 * @as(usize, version) + 9;
    setCell(modules, reserved, size, 8, dark_y, true);
    reserveFormat(reserved, size);
    if (version >= 7) {
        reserveVersion(reserved, size);
        placeVersionInfo(modules, size, version);
    }

    placeData(modules, reserved, size, interleaved[0..n_cw]);

    var work_buf: [max_modules]u8 = undefined;
    const work = work_buf[0 .. size * size];
    var best_mask: u8 = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var mask: u8 = 0;
    while (mask < 8) : (mask += 1) {
        applyMask(work, modules, reserved, size, mask);
        placeFormat(work, size, formatBitsL(mask));
        const score = penaltyScore(work, size);
        if (score < best_score) {
            best_score = score;
            best_mask = mask;
        }
    }

    applyMask(work, modules, reserved, size, best_mask);
    placeFormat(work, size, formatBitsL(best_mask));
    @memcpy(modules, work);

    return .{
        .size = size,
        .modules = modules,
        .version = version,
        .mask = best_mask,
    };
}

fn sampleDark(m: Matrix, x: i32, y: i32) bool {
    const q: i32 = 2;
    const mx = x - q;
    const my = y - q;
    if (mx < 0 or my < 0 or mx >= @as(i32, @intCast(m.size)) or my >= @as(i32, @intCast(m.size))) {
        return false;
    }
    return m.get(@intCast(mx), @intCast(my));
}

const glyph_full = "█";
const glyph_upper = "▀";
const glyph_lower = "▄";

fn pairGlyph(top_dark: bool, bot_dark: bool) []const u8 {
    // Inverse of a light-background QR: draw light modules, leave dark as space.
    if (!top_dark and !bot_dark) return glyph_full;
    if (!top_dark and bot_dark) return glyph_upper;
    if (top_dark and !bot_dark) return glyph_lower;
    return " ";
}

/// Memory: caller frees.
pub fn renderUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var m = try encode(allocator, text);
    defer m.deinit(allocator);
    const dim: usize = m.size + 4;
    const rows_out = (dim + 1) / 2;
    var buf = try std.ArrayList(u8).initCapacity(allocator, rows_out * (dim * 3 + 1));
    errdefer buf.deinit(allocator);

    var r: usize = 0;
    while (r < dim) : (r += 2) {
        var c: usize = 0;
        while (c < dim) : (c += 1) {
            const top = sampleDark(m, @intCast(c), @intCast(r));
            const bot = if (r + 1 < dim) sampleDark(m, @intCast(c), @intCast(r + 1)) else false;
            try buf.appendSlice(allocator, pairGlyph(top, bot));
        }
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// Memory: caller frees.
pub fn renderAscii(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var m = try encode(allocator, text);
    defer m.deinit(allocator);
    const dim: usize = m.size + 4;
    var buf = try std.ArrayList(u8).initCapacity(allocator, dim * (dim * 6 + 1));
    errdefer buf.deinit(allocator);

    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const dark = sampleDark(m, @intCast(x), @intCast(y));
            try buf.appendSlice(allocator, if (dark) "  " else "██");
        }
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

fn utf8Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        i += if (b < 0x80) @as(usize, 1) else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        n += 1;
    }
    return n;
}

test "GF(256) exp/log and RS remainder is zero" {
    var a: u8 = 1;
    while (true) {
        try std.testing.expectEqual(a, gf_exp[gf_log[a]]);
        if (a == 255) break;
        a += 1;
    }
    try std.testing.expectEqual(@as(u8, 1), gf_exp[0]);
    try std.testing.expectEqual(gfMul(gf_exp[3], gf_exp[5]), gf_exp[8]);
    try std.testing.expectEqual(gfMul(2, 2), @as(u8, 4));

    const data = [_]u8{ 0x40, 0xD4, 0x81, 0xA5, 0x47, 0x1A, 0x0C, 0x18, 0x2C, 0x19, 0x07, 0x12, 0x20, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
    const nsym: usize = 7;
    var gen: [31]u8 = undefined;
    buildGenerator(nsym, &gen);
    var ec: [7]u8 = undefined;
    rsEncode(&data, nsym, gen[0 .. nsym + 1], &ec);

    var shifted: [26]u8 = undefined;
    @memcpy(shifted[0..data.len], &data);
    @memset(shifted[data.len..], 0);
    var rem_ec: [7]u8 = undefined;
    polyMod(&shifted, gen[0 .. nsym + 1], nsym, &rem_ec);
    try std.testing.expectEqualSlices(u8, &ec, &rem_ec);

    var full: [26]u8 = undefined;
    @memcpy(full[0..data.len], &data);
    @memcpy(full[data.len..], &ec);
    var rem0: [7]u8 = undefined;
    polyMod(&full, gen[0 .. nsym + 1], nsym, &rem0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 7, &rem0);
}

test "version selection byte-mode L" {
    try std.testing.expectEqual(@as(?u8, 1), selectVersion(17));
    try std.testing.expectEqual(@as(u16, 19), dataCodewords(1));
    try std.testing.expectEqual(@as(?u8, 10), selectVersion(250));
    try std.testing.expectEqual(@as(?u8, 11), selectVersion(272));
    try std.testing.expect(selectVersion(1273) != null);
    try std.testing.expectEqual(@as(?u8, null), selectVersion(1274));

    var m17 = try encode(std.testing.allocator, "0123456789abcdefg");
    defer m17.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), m17.version);
    try std.testing.expectEqual(@as(usize, 21), m17.size);

    const a250 = "A" ** 250;
    var m250 = try encode(std.testing.allocator, a250);
    defer m250.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 10), m250.version);
    try std.testing.expectEqual(@as(usize, 57), m250.size);

    const a272 = "A" ** 272;
    var m272 = try encode(std.testing.allocator, a272);
    defer m272.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 11), m272.version);

    try std.testing.expectError(error.TooLong, encode(std.testing.allocator, "A" ** 1274));
}

test "format-info BCH level L mask 0 is 0x77C4" {
    try std.testing.expectEqual(@as(u16, 0x77C4), formatBitsL(0));
    try std.testing.expectEqual(@as(u32, 0x07C94), versionBch(7));
}

test "finder patterns and dark module" {
    var m = try encode(std.testing.allocator, "HELLO");
    defer m.deinit(std.testing.allocator);
    const s = m.size;
    try std.testing.expect(m.get(0, 0));
    try std.testing.expect(m.get(6, 0));
    try std.testing.expect(m.get(0, 6));
    try std.testing.expect(m.get(6, 6));
    try std.testing.expect(!m.get(1, 1));
    try std.testing.expect(m.get(3, 3));

    try std.testing.expect(m.get(s - 1, 0));
    try std.testing.expect(m.get(s - 7, 0));
    try std.testing.expect(m.get(s - 1, 6));
    try std.testing.expect(!m.get(s - 2, 1));
    try std.testing.expect(m.get(s - 4, 3));

    try std.testing.expect(m.get(0, s - 1));
    try std.testing.expect(m.get(6, s - 1));
    try std.testing.expect(m.get(0, s - 7));
    try std.testing.expect(!m.get(1, s - 2));
    try std.testing.expect(m.get(3, s - 4));

    const dark_y = 4 * @as(usize, m.version) + 9;
    try std.testing.expect(m.get(8, dark_y));
}

test "renderUtf8 line count and equal display width" {
    const out = try renderUtf8(std.testing.allocator, "https://wa.me/qr");
    defer std.testing.allocator.free(out);
    var m = try encode(std.testing.allocator, "https://wa.me/qr");
    defer m.deinit(std.testing.allocator);
    const expect_lines = (m.size + 4 + 1) / 2;
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');

    var n_lines: usize = 0;
    var width: ?usize = null;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n_lines += 1;
        const w = utf8Len(line);
        if (width) |pw| {
            try std.testing.expectEqual(pw, w);
        } else {
            width = w;
        }
    }
    try std.testing.expectEqual(expect_lines, n_lines);
    try std.testing.expectEqual(m.size + 4, width.?);
    const first = out[0..std.mem.indexOfScalar(u8, out, '\n').?];
    try std.testing.expectEqual(@as(usize, 0), first.len % 3);
    var gi: usize = 0;
    while (gi < first.len) : (gi += 3) {
        try std.testing.expectEqualSlices(u8, glyph_full, first[gi .. gi + 3]);
    }
}

test "encode is deterministic" {
    const text = "https://wa.me/settings/linked_devices#ref,abcd,efgh,ijkl,9";
    var a = try encode(std.testing.allocator, text);
    defer a.deinit(std.testing.allocator);
    var b = try encode(std.testing.allocator, text);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(a.size, b.size);
    try std.testing.expectEqual(a.version, b.version);
    try std.testing.expectEqual(a.mask, b.mask);
    try std.testing.expectEqualSlices(u8, a.modules, b.modules);
}

test "pairing-length 240-byte version and mask" {
    const text = "A" ** 240;
    var m = try encode(std.testing.allocator, text);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 10), m.version);
    std.debug.print("qr 240B version={d} mask={d} size={d}\n", .{ m.version, m.mask, m.size });
}
