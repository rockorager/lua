# The hash part: chained scatter table against open addressing, 2026-10-31

Plan decision 8 started the hash part as PUC-Rio's chained scatter table
with Brent's variation and left it to measure against open addressing.
This measures four open-addressing tables against it on every `bench/`
program, time and peak RSS. The chained table stays: every variant is
slower, the ones that fill to the same load as the chained table are much
slower, and the ones that grow earlier peak higher.

## What any layout must keep

- `next` continues after its loop body assigns to existing keys, nil
  included. In every variant here a key whose value becomes nil stays in
  its node (a tombstone) until the next resize, as in the chained table,
  and only inserting a new key moves anything, which the manual leaves
  undefined during a traversal.
- The collector's weak tables, ephemerons, and dead keys walk
  `t.nodes()` and read only a node's key, value, and tags (`gc.zig`'s
  `clearKey`, `markKey`, `clearByKeys`, `clearByValues`). A dead key keeps
  its node and its probe position, so a probe passes over it like a
  tombstone and `next` still finds it with `findNode(.., dead_ok)`.
- `GETTABUP`'s cache (`Proto.kslot`) holds a node index and checks the
  key there, so a layout that moves entries on insert costs misses, not
  correctness.

All variants keep the 24-byte `Node` (removing the chain's 4-byte `next`
leaves it at 24 for alignment; Robin Hood uses those 4 bytes for the
probe distance), the hash functions, the array part, and `rehash`'s
sizing; they change the probe, the insert, and when a hash part counts as
full. Each ran the unit tests and nextvar, gc, gengc, closure, sort, and
events from the suite.

- **lp87**: linear probing, growing at 7/8 load. A lookup stops at a
  never-used node or after the table's longest probe distance so far
  (`maxdist`, kept per table). A new key takes the first node with a nil
  value on its probe sequence.
- **lp100**: lp87 filling every node before it grows, as the chained
  table does, so the table sizes, and so memory, are the chained table's.
- **rh87**: Robin Hood at 7/8 load: an insert takes the place of any
  entry closer to its home than the one in hand and carries that one on;
  a miss stops at the first entry closer to its home than the probe.
- **rhh**: rh87, but hash parts of up to 8 nodes fill completely, so
  small records (an object's fields) take the chained table's sizes.

`SETLIST` sized the hash part from `nodeCount()`; with a load below 1
that doubles it, so the variants pass `hashCapacity()` instead.

## Measurements

ReleaseFast, interleaved, pinned to the last core, 10 rounds of every
program, benchstat; `chained` is f55ff31 in both runs. The machine is
noisy (±15% on single programs), so only the large effects count.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   chained    │                 lp87                 │                 lp100                  │
                  │    sec/op    │    sec/op     vs base                │    sec/op      vs base                 │
Lua/array           783.7m ± 15%   779.7m ± 20%        ~ (p=0.684 n=10)    758.2m ± 16%         ~ (p=0.631 n=10)
Lua/binary_trees    586.5m ± 15%   607.1m ± 14%        ~ (p=0.436 n=10)    601.8m ± 17%         ~ (p=0.796 n=10)
Lua/closures        529.5m ± 17%   519.0m ±  7%        ~ (p=0.218 n=10)    525.1m ±  4%         ~ (p=0.436 n=10)
Lua/concat          316.9m ± 19%   249.4m ±  5%  -21.29% (p=0.004 n=10)    321.9m ± 21%         ~ (p=0.971 n=10)
Lua/coroutines      350.1m ± 13%   376.3m ± 18%        ~ (p=0.631 n=10)    383.3m ± 20%         ~ (p=0.912 n=10)
Lua/fib             472.2m ± 14%   499.4m ± 20%   +5.76% (p=0.023 n=10)    497.5m ±  4%    +5.35% (p=0.019 n=10)
Lua/format          366.1m ±  9%   358.4m ± 17%        ~ (p=0.218 n=10)    347.7m ± 21%    -5.01% (p=0.043 n=10)
Lua/globals         538.4m ± 17%   556.2m ± 17%        ~ (p=0.684 n=10)    583.9m ± 21%         ~ (p=0.684 n=10)
Lua/hash_int        506.9m ± 10%   571.4m ±  3%  +12.74% (p=0.009 n=10)    591.6m ± 18%   +16.71% (p=0.043 n=10)
Lua/hash_string     518.0m ±  4%   615.7m ±  5%  +18.86% (p=0.001 n=10)   1355.3m ±  7%  +161.61% (p=0.000 n=10)
Lua/mandelbrot      455.0m ± 20%   452.0m ± 12%        ~ (p=0.971 n=10)    446.3m ±  7%         ~ (p=0.796 n=10)
Lua/methods         597.0m ± 10%   614.3m ± 13%        ~ (p=0.853 n=10)    603.9m ± 13%         ~ (p=0.796 n=10)
Lua/nbody           603.6m ± 12%   676.6m ± 11%  +12.10% (p=0.015 n=10)    697.2m ±  9%   +15.52% (p=0.004 n=10)
Lua/patterns        566.1m ± 11%   561.0m ± 20%        ~ (p=0.684 n=10)    557.4m ± 14%         ~ (p=0.393 n=10)
Lua/spectral_norm   618.8m ± 16%   635.8m ± 15%        ~ (p=0.971 n=10)    678.1m ± 21%         ~ (p=0.579 n=10)
Lua/table_concat    297.3m ± 21%   307.9m ± 20%        ~ (p=0.143 n=10)    301.9m ± 18%         ~ (p=0.529 n=10)
geomean             490.6m         502.8m         +2.47%                   539.4m          +9.94%

                  │   chained    │                 lp87                  │                 lp100                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │ peak-RSS-KiB  vs base                 │
Lua/array            20.93k ± 0%    20.94k ± 0%  +0.06% (p=0.000 n=10)      20.94k ± 0%  +0.04% (p=0.000 n=10)
Lua/binary_trees     26.60k ± 0%    27.75k ± 0%  +4.32% (p=0.000 n=10)      26.61k ± 0%  +0.03% (p=0.000 n=10)
Lua/closures         2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.000k ± 0%    6.008k ± 0%  +0.13% (p=0.000 n=10)      6.008k ± 0%  +0.13% (p=0.000 n=10)
Lua/hash_string      22.38k ± 0%    22.39k ± 0%  +0.05% (p=0.000 n=10)      22.38k ± 0%  +0.04% (p=0.000 n=10)
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.044k ± 0%    9.056k ± 0%  +0.13% (p=0.000 n=10)      9.052k ± 0%  +0.09% (p=0.000 n=10)
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     23.10k ± 0%    23.10k ± 0%  +0.03% (p=0.000 n=10)      23.10k ± 0%  +0.03% (p=0.000 n=10)
geomean              4.821k         4.835k       +0.29%                     4.822k       +0.02%
¹ all samples are equal
```

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   chained    │                 rh87                 │                 rhh                  │
                  │    sec/op    │    sec/op     vs base                │    sec/op     vs base                │
Lua/array           781.8m ± 15%   782.4m ± 10%        ~ (p=0.796 n=10)   698.2m ± 14%        ~ (p=0.218 n=10)
Lua/binary_trees    597.8m ± 19%   603.5m ±  5%        ~ (p=0.684 n=10)   612.0m ±  8%        ~ (p=0.393 n=10)
Lua/closures        511.0m ± 19%   526.7m ± 21%        ~ (p=0.393 n=10)   520.4m ± 20%        ~ (p=0.853 n=10)
Lua/concat          297.2m ± 14%   309.9m ± 10%        ~ (p=0.912 n=10)   327.2m ± 23%        ~ (p=1.000 n=10)
Lua/coroutines      374.0m ± 20%   400.8m ± 21%        ~ (p=0.853 n=10)   393.1m ± 12%        ~ (p=0.912 n=10)
Lua/fib             491.0m ±  8%   475.7m ± 14%        ~ (p=0.105 n=10)   487.5m ±  6%        ~ (p=0.631 n=10)
Lua/format          345.9m ±  6%   355.4m ± 10%        ~ (p=0.971 n=10)   353.1m ± 17%        ~ (p=0.912 n=10)
Lua/globals         511.9m ± 16%   512.6m ± 15%        ~ (p=0.481 n=10)   567.3m ± 10%  +10.83% (p=0.019 n=10)
Lua/hash_int        534.0m ± 20%   565.7m ± 21%        ~ (p=0.796 n=10)   623.0m ± 24%        ~ (p=0.075 n=10)
Lua/hash_string     528.0m ± 14%   714.8m ± 15%  +35.39% (p=0.000 n=10)   675.8m ± 12%  +27.99% (p=0.000 n=10)
Lua/mandelbrot      455.1m ± 14%   464.1m ±  8%        ~ (p=0.353 n=10)   455.9m ± 17%        ~ (p=1.000 n=10)
Lua/methods         596.2m ± 19%   606.5m ± 21%        ~ (p=0.280 n=10)   530.1m ± 15%        ~ (p=0.579 n=10)
Lua/nbody           629.4m ± 16%   745.0m ± 21%  +18.38% (p=0.015 n=10)   669.5m ± 13%        ~ (p=0.063 n=10)
Lua/patterns        551.3m ±  6%   565.1m ± 10%        ~ (p=0.353 n=10)   535.2m ± 17%        ~ (p=1.000 n=10)
Lua/spectral_norm   682.0m ± 16%   680.3m ±  5%        ~ (p=0.853 n=10)   675.4m ±  5%        ~ (p=0.579 n=10)
Lua/table_concat    301.4m ± 16%   294.0m ± 17%        ~ (p=0.247 n=10)   295.6m ± 17%        ~ (p=0.353 n=10)
geomean             494.0m         516.5m         +4.55%                  509.0m         +3.04%

                  │   chained    │                 rh87                  │                  rhh                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │ peak-RSS-KiB  vs base                 │
Lua/array            20.93k ± 0%    20.94k ± 0%  +0.06% (p=0.000 n=10)      20.94k ± 0%  +0.06% (p=0.000 n=10)
Lua/binary_trees     26.60k ± 0%    27.75k ± 0%  +4.32% (p=0.000 n=10)      27.38k ± 0%  +2.90% (p=0.000 n=10)
Lua/closures         2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/concat           2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/coroutines       2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/fib              2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/format           2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/globals          2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10)      2.368k ± 0%       ~ (p=1.000 n=10)
Lua/hash_int         6.000k ± 0%    6.008k ± 0%  +0.13% (p=0.000 n=10)      6.008k ± 0%  +0.13% (p=0.000 n=10)
Lua/hash_string      22.38k ± 0%    22.39k ± 0%  +0.05% (p=0.000 n=10)      22.39k ± 0%  +0.05% (p=0.000 n=10)
Lua/mandelbrot       2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.044k ± 0%    9.056k ± 0%  +0.13% (p=0.000 n=10)      9.056k ± 0%  +0.13% (p=0.000 n=10)
Lua/spectral_norm    2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     23.10k ± 0%    23.10k ± 0%  +0.03% (p=0.000 n=10)      23.10k ± 0%  +0.03% (p=0.000 n=10)
geomean              4.826k         4.840k       +0.29%                     4.836k       +0.20%
¹ all samples are equal
```

## Where the time goes

hash_string's phases on each table, from `os.clock` around each loop of
the program (15 passes of 100,000 keys in a table of 131,072 nodes, load
0.76; median of three runs, pinned, ms):

```
             insert   hit   miss   delete   lookups after deleting half
chained        170    109     61     27      56
lp87           174    128    106     32      65
rh87           203    171     79     36      76
rhh            206    172     79     37      76
```

The chained table's hits are its advantage: with Brent's variation a key
in a node that is not its main position is moved out when the owner
arrives, so most keys sit in their main position and a hit at load 0.76
looks at about 1 + α/2 = 1.4 nodes. Linear probing at the same load looks
at about (1 + 1/(1 − α))/2 = 2.6 nodes on a hit and (1 + 1/(1 − α)²)/2 =
9.2 on a miss. Adjacent nodes share cache lines, but at 24 bytes a node
2.6 probes still cross a line most of the time, and the chained table's
second probe is rare. Robin Hood bounds the miss (79 ms against 106) but
not the hit, and its loop carries the probe distance and compares it at
every step, which makes its hits the slowest of all (171 ms). At full
load (lp100) linear probing degenerates: the last keys into a nearly
full table probe a long way, and hash_string takes 2.6 times as long.

Peak memory: the variants that grow at 7/8 make tables in the top eighth
of a power of two twice as big, and record-sized tables bigger;
binary_trees peaks 4.3% higher with lp87 and rh87, 2.9% with rhh, and the
large hash tables of hash_int and hash_string, which sit at load 0.76,
do not change. lp100 and the chained table have the same sizes.

## Decision

Keep the chained scatter table. No open-addressing variant wins on time
(geomean +2.5% for lp87, +9.9% lp100, +4.6% rh87, +3.0% rhh, driven by
hash_string +19% to +162% and hash_int +13% to +17%), and the ones that
come closest pay in peak memory. A key in its main position on the first
probe is what the chained layout buys with its 4-byte link, and the link
costs nothing because the node pads to 24 bytes anyway.

The experiments lived in a scratch worktree; the probe and insert of the
two families, for whoever revisits this:

```zig
// lp87 / lp100: lookup
var i = s.hash & t.mask();
var left = t.maxdist;
while (true) {
    const n = &t.node[i];
    if (n.key_tag == .short_string and n.key.gc == &s.header) return n;
    if (n.key_tag == .nil or left == 0) return null;
    left -= 1;
    i = (i + 1) & t.mask();
}

// rh87 / rhh: insert of a key known to be absent (`next` holds the
// distance from the entry's main position)
if (t.isDummy() or t.free == 0) return false;
var cur: Node = .{ .key = key.payload, .key_tag = key.tag, .val = val.payload, .val_tag = val.tag, .next = 0 };
var i = t.mainPosition(key.tag, key.payload);
while (true) {
    const n = &t.node[i];
    if (n.key_tag == .nil) {
        t.free -= 1;
        n.* = cur;
        return true;
    }
    if (n.val_tag == .nil and n.next <= cur.next) {
        n.* = cur; // a tombstone no farther from home: reuse it
        return true;
    }
    if (n.next < cur.next) std.mem.swap(Node, n, &cur);
    cur.next += 1;
    i = (i + 1) & t.mask();
}
```
