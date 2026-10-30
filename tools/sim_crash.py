"""Faithful simulation of regolith's Db + crash_test run_case, to diff against
the real MoonBit implementation. Models the v0.4 multi-file design
(docs/design-multifile.md): memtable (dict + size accounting), group-commit
WAL (10-byte tomb / 11-byte live records, batch records), L0 tables, many
L1/L2 tables with disjoint key ranges (selective merges, output split at
table_size_limit, L<l>_<S>_<G>.sst naming), tombstones kept in L1 and
suppressed at the bottom, the L2 size trigger, compaction trigger 3, memtable
limit 512, the five fault kinds, and the op-log model with prefix truncation
after crashes. A batch is one op boundary (one WAL record), so no prefix may
split it.

Recovery mirrors the engine exactly: L2 union-coverage drop, L1 keep-all
(legacy full-merge rules for G-less names), L0 covered by L1 union or legacy
L2, full WAL replay (no skipping), next_seq over every surviving seq.

Dev tool, not part of the library: run `python -I tools/sim_crash.py` to
validate the crash-consistency design against the spec independently of the
MoonBit code — 200 seeds by default, or pass a count
(`python -I tools/sim_crash.py 50`). All 200 seeds pass.

Diagnosed with it: the only real engine bug found by the crash suite was a
skip-list orphan node in MemTable::put (fixed); the flush/compact/recover
logic itself is consistent with the model."""

M = (1 << 64) - 1


def xorshift(x):
    x ^= (x << 13) & M
    x ^= x >> 7
    x ^= (x << 17) & M
    return x


def size_of(value):
    return 1 + (1 if value is not None else 0) + 24


def rec_bytes(r):
    if len(r) == 3:
        # len varint(1) + crc(4) + op(1) + seq(1) + kl(1) + key(1) + vl(1) [+ val(1)]
        return 1 + 4 + 1 + 1 + 1 + 1 + 1 + (0 if r[1] is None else 1)
    # batch: len(1) + crc(4) + op(1) + seq(1) + n(1) + per entry op(1)+kl(1)+key(1)+vl(1)[+val(1)]
    _op, base, entries = r
    return 1 + 4 + 1 + 1 + 1 + sum(4 + (0 if v is None else 1) for _k, v in entries)


class Table:
    __slots__ = ('name', 'S', 'lo', 'hi', 'tbl', 'legacy')

    def __init__(self, name, S, tbl, legacy):
        self.name = name
        self.S = S
        self.lo = min(tbl)
        self.hi = max(tbl)
        self.tbl = dict(tbl)
        self.legacy = legacy

    def bytes(self):
        return 45 + 7 * len(self.tbl)


class DB:
    def __init__(self, storage, opts):
        self.storage = storage          # name -> list of (key, value, seq) records (files)
        self.opts = opts
        self.memtable = {}              # key -> (value, seq)
        self.size = 0
        self.wal_buf = []
        self.l0 = []                    # list of (name, dict key->(value,seq))
        self.l0_counter = 0
        self.l1 = []                    # list of Table, S descending
        self.l1_bytes = 0
        self.l2 = []                    # list of Table, S descending
        self.l2_bytes = 0
        self.table_gen = 1
        self.next_seq = 0
        self.recover()

    # ---- storage ops with fault injection ----
    def write(self, name, records, fp):
        if fp is None:
            self.storage[name] = list(records)
            return
        kind, prefix = fp.get('kind'), fp.get('prefix')
        if kind is not None:
            match = (prefix is None or name.startswith(prefix))
            if kind == 'TornWrite' and match:
                fp['kind'] = None  # one-shot
                if name == 'WAL':
                    # the first half of the bytes reaches the medium; the
                    # surviving full records replay on recovery
                    total = sum(rec_bytes(r) for r in records)
                    kept, acc = [], 0
                    for r in records:
                        if acc + rec_bytes(r) > total // 2:
                            break
                        kept.append(r); acc += rec_bytes(r)
                    self.storage[name] = kept
                else:
                    # half a table has no footer: dropped entirely on recovery
                    self.storage[name] = ['TORN']
                raise RuntimeError(f"torn write {name}")
            if kind == 'LostWrite' and name == 'WAL':
                fp['kind'] = None  # one-shot: reports success, nothing lands
                return
        self.storage[name] = list(records)

    def remove(self, name):
        self.storage.pop(name, None)

    def list(self, prefix):
        return sorted(n for n in self.storage if n.startswith(prefix))

    def parse_name(self, name):
        """L<l>_<S>.sst (legacy) or L<l>_<S>_<G>.sst (current)."""
        if not (name.startswith('L1_') or name.startswith('L2_')):
            return None
        if not name.endswith('.sst'):
            return None
        body = name[3:-4]
        parts = body.split('_')
        if not parts[0].isdigit():
            return None
        S = int(parts[0])
        if len(parts) == 1:
            return S, 0, True
        if len(parts) == 2 and parts[1].isdigit():
            return S, int(parts[1]), False
        return None

    def insert_desc(self, tables, t):
        """Mirror of insert_table: keep S descending, new equal-S after old."""
        out = []
        done = False
        for u in tables:
            if not done and u.S < t.S:
                out.append(t)
                done = True
            out.append(u)
        if not done:
            out.append(t)
        return out

    def covered_by(self, t, candidates):
        """Mirror of Db::covered_by: single-range containment fast path, then
        a key-space union walk over t's own keys."""
        for u in candidates:
            if u.S >= t.S and u.lo <= t.lo and u.hi >= t.hi:
                return True
        cands = [u for u in candidates
                 if u.S >= t.S and u.lo <= t.hi and u.hi >= t.lo]
        if not cands:
            return False
        cands.sort(key=lambda u: u.lo)
        ci = 0
        for k in sorted(t.tbl):
            while ci < len(cands) and cands[ci].hi < k:
                ci += 1
            if ci >= len(cands) or cands[ci].lo > k:
                return False
        return True

    # ---- recovery ----
    def recover(self):
        max_gen = 0
        max_seq = 0

        # L2: load every valid table, then drop those provably merged into
        # newer ones (the coverage test needs the full set).
        loaded2 = []
        for name in self.list('L2_'):
            p = self.parse_name(name)
            if p is None:
                self.remove(name)
                continue
            S, gen, legacy = p
            if not legacy:
                max_gen = max(max_gen, gen)
            if self.storage[name] == ['TORN']:
                self.remove(name)
                continue
            loaded2.append(Table(name, S, dict(self.storage[name]), legacy))
        kept2 = []
        legacy_l2_s = 0
        for t in loaded2:
            others = [u for u in loaded2 if u.name != t.name]
            if self.covered_by(t, others):
                self.remove(t.name)
            else:
                max_seq = max(max_seq, t.S)
                if t.legacy:
                    legacy_l2_s = max(legacy_l2_s, t.S)
                kept2 = self.insert_desc(kept2, t)
        self.l2 = kept2
        self.l2_bytes = sum(t.bytes() for t in kept2)

        # L1 keep-all; only legacy L1 fully merged into a surviving legacy
        # L2 (S >=) can be dropped.
        kept1 = []
        for name in self.list('L1_'):
            p = self.parse_name(name)
            if p is None:
                self.remove(name)
                continue
            S, gen, legacy = p
            if not legacy:
                max_gen = max(max_gen, gen)
            if self.storage[name] == ['TORN']:
                self.remove(name)
                continue
            t = Table(name, S, dict(self.storage[name]), legacy)
            if t.legacy and legacy_l2_s > 0 and legacy_l2_s >= t.S:
                self.remove(name)
            else:
                max_seq = max(max_seq, t.S)
                kept1 = self.insert_desc(kept1, t)
        self.l1 = kept1
        self.l1_bytes = sum(t.bytes() for t in kept1)

        # L0: drop tables whose every key is covered by L1 tables with
        # S >= the table's max seq, or by a surviving legacy L2.
        max_l0_num = -1
        l0s = []
        for name in self.list('L0_'):
            num = int(name.split('_')[1].split('.')[0])
            max_l0_num = max(max_l0_num, num)
            if self.storage[name] == ['TORN']:
                self.remove(name)
                continue
            tbl = dict(self.storage[name])
            m = max((s for _v, s in tbl.values()), default=0)
            t = Table(name, m, tbl, False)
            if self.covered_by(t, kept1) or (legacy_l2_s > 0 and m <= legacy_l2_s):
                self.remove(name)
            else:
                max_seq = max(max_seq, m)
                l0s.append((name, tbl))
        self.l0_counter = max_l0_num + 1
        self.l0 = l0s
        self.table_gen = max_gen + 1
        self.memtable = {}
        self.size = 0
        # WAL: replay every valid record (no coverage skipping).
        wal = self.storage.get('WAL')
        self.wal_buf = list(wal) if wal is not None else []
        for rec in self.wal_buf:
            if rec[0] != 'BATCH':
                key, value, seq = rec
                self.memtable[key] = (value, seq)
                self.size += size_of(value)
            else:
                _op, base, entries = rec
                for i, (key, value) in enumerate(entries):
                    self.memtable[key] = (value, base + i)
                    self.size += size_of(value)
        mem_seq = max((s for _v, s in self.memtable.values()), default=0)
        self.next_seq = max(mem_seq, max_seq) + 1

    # ---- operations ----
    def put(self, key, value, fp=None):
        self.next_seq += 1
        seq = self.next_seq - 1
        if key in self.memtable:
            self.size -= size_of(self.memtable[key][0])
        self.memtable[key] = (value, seq)
        self.size += size_of(value)
        self.wal_buf.append((key, value, seq))
        if self.size >= self.opts['memtable_limit']:
            self.flush(fp)

    def batch(self, entries, fp=None):
        base = self.next_seq
        self.next_seq += len(entries)
        for i, (key, value) in enumerate(entries):
            if key in self.memtable:
                self.size -= size_of(self.memtable[key][0])
            self.memtable[key] = (value, base + i)
            self.size += size_of(value)
        self.wal_buf.append(('BATCH', base, list(entries)))
        if self.size >= self.opts['memtable_limit']:
            self.flush(fp)

    def flush(self, fp=None):
        if not self.memtable:
            if self.wal_buf:
                self.wal_buf = []
                self.storage['WAL'] = []
            return
        self.write('WAL', self.wal_buf, fp)
        tbl = dict(self.memtable)
        name = f"L0_{self.l0_counter:06d}.sst"
        self.write(name, sorted(tbl.items()), fp)
        self.l0.append((name, tbl))
        self.l0_counter += 1
        self.write('WAL', [], fp)
        self.wal_buf = []
        self.memtable = {}
        self.size = 0
        if len(self.l0) >= self.opts['l0_compaction_trigger']:
            self.compact(fp)
            self.maybe_compact_l2(fp)

    def merge_into(self, merged, tbl):
        for k, (v, s) in tbl.items():
            if k not in merged or s > merged[k][1]:
                merged[k] = (v, s)

    def split_pieces(self, level, merged, fp):
        """Mirror of merge_to_tables: split at table_size_limit, each piece
        named L<l>_<S>_<G> with S = the piece's max seq."""
        limit = self.opts['table_size_limit']
        pieces = []
        piece = {}
        piece_seq = 0
        for k in sorted(merged):
            v, s = merged[k]
            est = 1 + (1 if v is not None else 0) + 32
            if piece and 45 + 7 * len(piece) + est >= limit:
                self.seal_piece(level, piece, piece_seq, pieces, fp)
                piece = {}
                piece_seq = 0
            piece[k] = (v, s)
            piece_seq = max(piece_seq, s)
        if piece:
            self.seal_piece(level, piece, piece_seq, pieces, fp)
        return pieces

    def seal_piece(self, level, piece, piece_seq, pieces, fp):
        gen = self.table_gen
        self.table_gen += 1
        name = f"{level}_{piece_seq}_{gen}.sst"
        self.write(name, sorted(piece.items()), fp)
        pieces.append(Table(name, piece_seq, piece, False))

    def compact(self, fp=None):
        # L0 -> L1: every L0 table plus the L1 tables whose ranges overlap
        # the L0 span; tombstones KEPT (non-bottom). No-op while L0 is empty.
        if not self.l0:
            return
        merged = {}
        lo_min = min(k for _n, tbl in self.l0 for k in tbl)
        lo_max = max(k for _n, tbl in self.l0 for k in tbl)
        consumed1 = []
        kept1 = []
        for t in self.l1:
            if t.lo <= lo_max and t.hi >= lo_min:
                self.merge_into(merged, t.tbl)
                consumed1.append(t)
            else:
                kept1.append(t)
        for _name, tbl in self.l0:
            self.merge_into(merged, tbl)
        pieces = self.split_pieces('L1', merged, fp)
        # Inputs are released oldest-first (ascending S), then the L0s.
        for t in sorted(consumed1, key=lambda t: t.S):
            self.remove(t.name)
        for name, _tbl in self.l0:
            self.remove(name)
        self.l0 = []
        l1 = kept1
        for t in pieces:
            l1 = self.insert_desc(l1, t)
        self.l1 = l1
        self.l1_bytes = sum(t.bytes() for t in l1)

    def compact_l2(self, fp=None):
        # L1 -> L2 (selective): the oldest L1 plus every L1/L2 table whose
        # range overlaps it; tombstones suppressed. No-op while L1 is empty.
        if not self.l1:
            return
        picked = self.l1[-1]
        merged = {}
        consumed1 = []
        kept1 = []
        for t in self.l1:
            if t.lo <= picked.hi and t.hi >= picked.lo:
                self.merge_into(merged, t.tbl)
                consumed1.append(t)
            else:
                kept1.append(t)
        consumed2 = []
        kept2 = []
        for t in self.l2:
            if t.lo <= picked.hi and t.hi >= picked.lo:
                self.merge_into(merged, t.tbl)
                consumed2.append(t)
            else:
                kept2.append(t)
        live = {k: (v, s) for k, (v, s) in merged.items() if v is not None}
        pieces = self.split_pieces('L2', live, fp)
        # L2 inputs first, then L1 inputs, oldest-first within each level.
        for t in sorted(consumed2, key=lambda t: t.S):
            self.remove(t.name)
        for t in sorted(consumed1, key=lambda t: t.S):
            self.remove(t.name)
        self.l1 = kept1
        self.l1_bytes = sum(t.bytes() for t in kept1)
        l2 = kept2
        for t in pieces:
            l2 = self.insert_desc(l2, t)
        self.l2 = l2
        self.l2_bytes = sum(t.bytes() for t in l2)

    def maybe_compact_l2(self, fp=None):
        # Loop: each round consumes at least one L1 table, so it terminates.
        while self.l1 and self.l1_bytes >= self.opts['l2_size_trigger'] and (
                self.l2_bytes == 0
                or self.l1_bytes * self.opts['l2_size_ratio'] >= self.l2_bytes):
            self.compact_l2(fp)

    def state(self):
        merged = {}
        for t in self.l2:
            for k, (v, s) in t.tbl.items():
                if k not in merged or s > merged[k][1]:
                    merged[k] = (v, s)
        for t in self.l1:
            for k, (v, s) in t.tbl.items():
                if k not in merged or s > merged[k][1]:
                    merged[k] = (v, s)
        for _n, tbl in self.l0:
            for k, (v, s) in tbl.items():
                if k not in merged or s > merged[k][1]:
                    merged[k] = (v, s)
        for k, (v, s) in self.memtable.items():
            if k not in merged or s > merged[k][1]:
                merged[k] = (v, s)
        return {k: v for k, (v, s) in merged.items() if v is not None}

    def dump(self):
        mem = sorted((k, v, s) for k, (v, s) in self.memtable.items())
        l1s = [t.name for t in self.l1]
        l2s = [t.name for t in self.l2]
        return (f"mem_bytes={self.size} wal={sum(rec_bytes(r) for r in self.wal_buf)} "
                f"l0={len(self.l0)} l1={l1s} l2={l2s}\n"
                f"mem:{mem}\nfiles:{self.list('')}\n"
                f"l0_names:{[n for n,_ in self.l0]} "
                f"next_seq={self.next_seq} gen={self.table_gen}")


def replay(ops, s):
    m = {}
    for entries in ops[:s]:
        for k, v in entries:
            if v is None:
                m.pop(k, None)
            else:
                m[k] = v
    return m


def run_case(seed, trace=True, stop_at=None):
    storage = {}
    opts = {'memtable_limit': 512, 'l0_compaction_trigger': 3,
            'l2_size_trigger': 20, 'l2_size_ratio': 4,
            'table_size_limit': 2097152}
    db = DB(storage, opts)
    ops = []
    x = seed
    log = []
    for step in range(40):
        x = xorshift(x)
        r = x
        key = (r >> 4) % 8
        op = r % 12
        fp = {'kind': None, 'prefix': None}
        if op < 5:
            value = (r >> 8) % 256
            db.put(key, value)
            ops.append([(key, value)])
            exact = True
        elif op < 7:
            db.put(key, None)
            ops.append([(key, None)])
            exact = True
        elif op == 7:
            key2 = key ^ 1
            v1 = (r >> 8) % 256
            v2 = (r >> 16) % 256
            db.batch([(key, v1), (key2, v2)])
            ops.append([(key, v1), (key2, v2)])
            exact = True
        elif op == 8:
            db.flush()
            exact = True
        elif op == 9:
            db = DB(storage, opts)
            s = prefix_check(ops, db)
            ops = ops[:s]
            log.append(f"step {step}: plain crash -> s={s}")
            exact = False
        else:
            db.put(key, 0x78)  # b"x"
            ops.append([(key, 0x78)])
            kind = (r >> 8) % 5
            if kind == 0:
                fp = {'kind': 'LostWrite', 'prefix': None}
            elif kind == 1:
                fp = {'kind': 'TornWrite', 'prefix': 'WAL'}
            elif kind == 2:
                fp = {'kind': 'TornWrite', 'prefix': 'L0_'}
            elif kind == 3:
                fp = {'kind': 'TornWrite', 'prefix': 'L1_'}
            else:
                fp = {'kind': 'TornWrite', 'prefix': 'L2_'}
            try:
                db.flush(fp)
            except RuntimeError:
                pass
            db = DB(storage, opts)
            s = prefix_check(ops, db)
            ops = ops[:s]
            log.append(f"step {step}: fault kind={kind} -> s={s}")
            exact = False
        if exact:
            want = replay(ops, len(ops))
            got = db.state()
            if want != got:
                print(f"DIVERGENCE at step {step}")
                print(f"  ops: {ops}")
                print(f"  want: {want}")
                print(f"  got:  {got}")
                print(f"  {db.dump()}")
                for l in log:
                    print(f"  {l}")
                if stop_at is not None and step >= stop_at:
                    return
    return db, ops


def prefix_check(ops, db):
    got = db.state()
    for s in range(len(ops), -1, -1):
        if replay(ops, s) == got:
            return s
    raise AssertionError("PREFIX FAIL")


if __name__ == '__main__':
    import sys
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    for s in range(1, n + 1):
        run_case(s, trace=False)
    print(f"all {n} seeds pass")
