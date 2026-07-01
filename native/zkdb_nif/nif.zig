//! zkdb_nif — Erlang NIF bridge for zkdb.
//!
//! Exposes core zkdb operations to the Elixir/BEAM layer:
//!   sum_f64(list) → float
//!   avg_f64(list) → float
//!   asof_join(left_ts, right_ts) → [indices]
//!   wj_sum(sym_l, ts_l, sym_r, ts_r, data_r, window_ns) → [floats]
//!
//! Zig data plane. Elixir control plane (see lib/zkdb_elixir.ex).

const std = @import("std");
const c = @cImport({
    @cInclude("erl_nif.h");
});

// We use a GPA per-NIF invocation with 4MB stack space.
var gpa_state: std.heap.DebugAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

// ---- SIMD vector sum (mirrors zkdb vector.zig) ----

fn simdWidth(comptime T: type) comptime_int {
    return switch (@sizeOf(T)) { 8 => 4, 4 => 8, 2 => 16, 1 => 32, else => 1 };
}

fn vecSum(comptime T: type, items: []const T) T {
    const W = simdWidth(T);
    const Vec = @Vector(W, T);
    var acc: T = 0;
    var i: usize = 0;
    while (i + W <= items.len) : (i += W) {
        const v: Vec = items[i..][0..W].*;
        acc += @reduce(.Add, v);
    }
    while (i < items.len) : (i += 1) acc += items[i];
    return acc;
}

fn vecAvg(comptime T: type, items: []const T) f64 {
    if (items.len == 0) return 0.0;
    var s: f64 = 0.0;
    for (items) |x| s += @as(f64, @floatCast(x));
    return s / @as(f64, @floatFromInt(items.len));
}

// ---- Binary search for asof join ----
fn asofSearch(right_ts: []const i64, t: i64) usize {
    var lo: usize = 0;
    var hi: usize = right_ts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (right_ts[mid] <= t) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) std.math.maxInt(usize) else lo - 1;
}

// ---- NIF helpers ----

fn listToF64Slice(env: ?*c.ErlNifEnv, term: c.ERL_NIF_TERM, allocator: std.mem.Allocator) ![]f64 {
    var len: c_uint = 0;
    if (c.enif_get_list_length(env, term, &len) == 0) return error.BadArg;
    const out = try allocator.alloc(f64, @intCast(len));
    errdefer allocator.free(out);
    var list = term;
    for (0..@intCast(len)) |i| {
        var head: c.ERL_NIF_TERM = undefined;
        var tail: c.ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, list, &head, &tail) == 0) return error.BadArg;
        if (c.enif_get_double(env, head, &out[i]) == 0) {
            // Try int
            var vi: c_long = 0;
            if (c.enif_get_long(env, head, &vi) == 0) return error.BadArg;
            out[i] = @floatFromInt(vi);
        }
        list = tail;
    }
    return out;
}

fn listToI64Slice(env: ?*c.ErlNifEnv, term: c.ERL_NIF_TERM, allocator: std.mem.Allocator) ![]i64 {
    var len: c_uint = 0;
    if (c.enif_get_list_length(env, term, &len) == 0) return error.BadArg;
    const out = try allocator.alloc(i64, @intCast(len));
    errdefer allocator.free(out);
    var list = term;
    for (0..@intCast(len)) |i| {
        var head: c.ERL_NIF_TERM = undefined;
        var tail: c.ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, list, &head, &tail) == 0) return error.BadArg;
        var vi: c_long = 0;
        if (c.enif_get_long(env, head, &vi) == 0) return error.BadArg;
        out[i] = @intCast(vi);
        list = tail;
    }
    return out;
}

fn badArg(env: ?*c.ErlNifEnv) c.ERL_NIF_TERM {
    return c.enif_make_badarg(env);
}

// ---- NIF: zkdb_sum_f64(List :: [float]) → float ----
export fn nif_sum_f64(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 1) return badArg(env);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = listToF64Slice(env, argv[0], arena.allocator()) catch return badArg(env);
    const result = vecSum(f64, items);
    return c.enif_make_double(env, result);
}

// ---- NIF: zkdb_avg_f64(List :: [float]) → float ----
export fn nif_avg_f64(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 1) return badArg(env);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = listToF64Slice(env, argv[0], arena.allocator()) catch return badArg(env);
    const result = vecAvg(f64, items);
    return c.enif_make_double(env, result);
}

// ---- NIF: zkdb_asof_join(LeftTs :: [integer], RightTs :: [integer]) → [integer] ----
// Returns a list of right indices (one per left row), maxInt(usize) for no-match.
export fn nif_asof_join(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 2) return badArg(env);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const left_ts  = listToI64Slice(env, argv[0], alloc) catch return badArg(env);
    const right_ts = listToI64Slice(env, argv[1], alloc) catch return badArg(env);

    const indices = alloc.alloc(usize, left_ts.len) catch return badArg(env);
    for (left_ts, 0..) |t, i| {
        indices[i] = asofSearch(right_ts, t);
    }

    // Build result list
    const terms = alloc.alloc(c.ERL_NIF_TERM, left_ts.len) catch return badArg(env);
    for (indices, 0..) |idx, i| {
        terms[i] = if (idx == std.math.maxInt(usize))
            c.enif_make_atom(env, "nil")
        else
            c.enif_make_long(env, @intCast(idx));
    }
    return c.enif_make_list_from_array(env, terms.ptr, @intCast(terms.len));
}

// ---- NIF: zkdb_wj_sum(SymL, TsL, SymR, TsR, DataR, WindowNs) → [float] ----
// All sym arguments are lists of integers (already-interned symbol IDs).
export fn nif_wj_sum(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 6) return badArg(env);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sym_l_i64 = listToI64Slice(env, argv[0], alloc) catch return badArg(env);
    const ts_l      = listToI64Slice(env, argv[1], alloc) catch return badArg(env);
    const sym_r_i64 = listToI64Slice(env, argv[2], alloc) catch return badArg(env);
    const ts_r      = listToI64Slice(env, argv[3], alloc) catch return badArg(env);
    const data_r    = listToF64Slice(env, argv[4], alloc) catch return badArg(env);
    var window_ns: c_long = 0;
    if (c.enif_get_long(env, argv[5], &window_ns) == 0) return badArg(env);

    if (sym_l_i64.len != ts_l.len or sym_r_i64.len != ts_r.len or sym_r_i64.len != data_r.len)
        return badArg(env);

    // Cast i64 sym IDs to u32 for wj (symbols are u32 in zkdb)
    const sym_l = alloc.alloc(u32, sym_l_i64.len) catch return badArg(env);
    for (sym_l_i64, 0..) |s, i| sym_l[i] = @intCast(@max(0, s));
    const sym_r = alloc.alloc(u32, sym_r_i64.len) catch return badArg(env);
    for (sym_r_i64, 0..) |s, i| sym_r[i] = @intCast(@max(0, s));

    // Inline window join sum (copy of wj.wjSumF64 logic to avoid import cycle)
    const out = alloc.alloc(f64, sym_l.len) catch return badArg(env);
    @memset(out, 0.0);

    // Build per-sym sorted index
    var groups = std.AutoHashMap(u32, std.array_list.Managed(usize)).init(alloc);
    for (0..sym_r.len) |i| {
        const g = groups.getOrPut(sym_r[i]) catch return badArg(env);
        if (!g.found_existing) g.value_ptr.* = std.array_list.Managed(usize).init(alloc);
        g.value_ptr.append(i) catch return badArg(env);
    }

    var idx_map = std.AutoHashMap(u32, struct { ts: []i64, rows: []usize }).init(alloc);
    var git = groups.iterator();
    while (git.next()) |ge| {
        const rows = alloc.dupe(usize, ge.value_ptr.items) catch return badArg(env);
        std.mem.sort(usize, rows, ts_r, struct {
            fn lt(ctx: []const i64, a: usize, b: usize) bool { return ctx[a] < ctx[b]; }
        }.lt);
        const ts_sorted = alloc.alloc(i64, rows.len) catch return badArg(env);
        for (rows, 0..) |r, i| ts_sorted[i] = ts_r[r];
        idx_map.put(ge.key_ptr.*, .{ .ts = ts_sorted, .rows = rows }) catch return badArg(env);
    }

    for (sym_l, 0..) |sym, i| {
        const t = ts_l[i];
        const entry = idx_map.get(sym) orelse continue;
        // Find window [t - window_ns, t]
        const lo_ts = t - window_ns;
        var lo: usize = 0; var hi_lo: usize = entry.ts.len;
        while (lo < hi_lo) { const mid = lo + (hi_lo - lo) / 2; if (entry.ts[mid] < lo_ts) lo = mid + 1 else hi_lo = mid; }
        var hi: usize = lo; var hi_hi: usize = entry.ts.len;
        while (hi < hi_hi) { const mid = hi + (hi_hi - hi) / 2; if (entry.ts[mid] <= t) hi = mid + 1 else hi_hi = mid; }
        for (entry.rows[lo..hi]) |r| out[i] += data_r[r];
    }

    // Return as list
    const terms = alloc.alloc(c.ERL_NIF_TERM, out.len) catch return badArg(env);
    for (out, 0..) |v, i| terms[i] = c.enif_make_double(env, v);
    return c.enif_make_list_from_array(env, terms.ptr, @intCast(terms.len));
}

// ---- NIF function table ----
const nif_funcs = [_]c.ErlNifFunc{
    .{ .name = "sum_f64",   .arity = 1, .fptr = nif_sum_f64,   .flags = 0 },
    .{ .name = "avg_f64",   .arity = 1, .fptr = nif_avg_f64,   .flags = 0 },
    .{ .name = "asof_join", .arity = 2, .fptr = nif_asof_join, .flags = 0 },
    .{ .name = "wj_sum",    .arity = 6, .fptr = nif_wj_sum,    .flags = 0 },
};

export fn nif_load(_: ?*c.ErlNifEnv, _: [*c]?*anyopaque, _: c.ERL_NIF_TERM) c_int {
    return 0;
}

export const zkdb_nif_entry: c.ErlNifEntry = .{
    .major = c.ERL_NIF_MAJOR_VERSION,
    .minor = c.ERL_NIF_MINOR_VERSION,
    .name = "Elixir.ZkdbElixir",
    .num_of_funcs = nif_funcs.len,
    .funcs = @constCast(&nif_funcs[0]),
    .load = nif_load,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = c.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = @sizeOf(c.ErlNifResourceTypeInit),
    .min_erts = c.ERL_NIF_MIN_ERTS_VERSION,
};

export fn nif_init() *const c.ErlNifEntry {
    return &zkdb_nif_entry;
}
