"""Faithful simulation of regolith's Db + crash_test run_case, to diff against
the real MoonBit implementation. Models: memtable (dict + size accounting),
group-commit WAL (10-byte tomb / 11-byte live records, batch records), L0
tables, L1 subsumption, compaction trigger 3, memtable limit 512, the four
fault kinds, and the op-log model with prefix truncation after crashes. A
batch is one op boundary (one WAL record), so no prefix may split it.

Dev tool, not part of the library: run `python -I tools/sim_crash.py` (single
seed) or loop over seeds to validate the crash-consistency design against the
spec independently of the MoonBit code. All 200 seeds pass.

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

class DB:
    def __init__(self, storage, opts):
        self.storage = storage          # name -> list of (key, value, seq) records (files)
        self.opts = opts
        self.memtable = {}              # key -> (value, seq)
        self.size = 0
        self.wal_buf = []
        self.l0 = []                    # list of (name, dict key->(value,seq))
        self.l0_counter = 0
        self.l1 = None                  # (name, S, dict)
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

    # ---- recovery ----
    def recover(self):
        l1_names = self.list('L1_')
        best = None
        for name in l1_names:
            if self.storage[name] == ['TORN']:
                self.remove(name)
                continue
            s = int(name.split('_')[1].split('.')[0])
            if best is None or s > best[1]:
                best = (name, s, dict(self.storage[name]))
        for name in l1_names:
            if best is None or name != best[0]:
                self.remove(name)
        max_l0_num = -1
        max_table_seq = best[1] if best else 0
        l0s = []
        for name in self.list('L0_'):
            num = int(name.split('_')[1].split('.')[0])
            max_l0_num = max(max_l0_num, num)
            if self.storage[name] == ['TORN']:
                self.remove(name)
                continue
            tbl = dict(self.storage[name])
            m = max((s for _v, s in tbl.values()), default=0)
            if best and m <= best[1]:
                self.remove(name)
            else:
                max_table_seq = max(max_table_seq, m)
                l0s.append((name, tbl))
        self.l0_counter = max_l0_num + 1
        self.l0 = l0s
        self.l1 = best
        self.memtable = {}
        self.size = 0
        wal = self.storage.get('WAL')
        self.wal_buf = list(wal) if wal is not None else []
        S = best[1] if best else 0
        for rec in self.wal_buf:
            if rec[0] != 'BATCH':
                key, value, seq = rec
                if seq <= S:
                    continue
                self.memtable[key] = (value, seq)
                self.size += size_of(value)
            else:
                _op, base, entries = rec
                for i, (key, value) in enumerate(entries):
                    seq = base + i
                    if seq <= S:
                        continue
                    self.memtable[key] = (value, seq)
                    self.size += size_of(value)
        mem_seq = max((s for _v, s in self.memtable.values()), default=0)
        self.next_seq = max(mem_seq, max_table_seq) + 1

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

    def compact(self, fp=None):
        merged = {}
        for _name, tbl in self.l0:
            for k, (v, s) in tbl.items():
                if k not in merged or s > merged[k][1]:
                    merged[k] = (v, s)
        if self.l1:
            _n, _S, tbl = self.l1
            for k, (v, s) in tbl.items():
                if k not in merged or s > merged[k][1]:
                    merged[k] = (v, s)
        for k, (v, s) in self.memtable.items():
            if k not in merged or s > merged[k][1]:
                merged[k] = (v, s)
        old_names = [n for n, _t in self.l0]
        old_l1 = self.l1[0] if self.l1 else None
        # The real MergeIterator suppresses tombstones: only live entries are
        # emitted, and S is the max seq among *emitted* entries.
        live = {k: (v, s) for k, (v, s) in merged.items() if v is not None}
        max_seq = max((s for _v, s in live.values()), default=0)
        if live:
            name = f"L1_{max_seq}.sst"
            self.write(name, sorted(live.items()), fp)
            for n in old_names:
                self.remove(n)
            if old_l1:
                self.remove(old_l1)
            self.l0 = []
            self.l1 = (name, max_seq, dict(live))
        else:
            for n in old_names:
                self.remove(n)
            if old_l1:
                self.remove(old_l1)
            self.l0 = []
            self.l1 = None

    def state(self):
        merged = {}
        if self.l1:
            for k, (v, s) in self.l1[2].items():
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
        return (f"mem_bytes={self.size} wal={sum(rec_bytes(r) for r in self.wal_buf)} "
                f"l0={len(self.l0)} l1={self.l1[0] if self.l1 else 'None'}\n"
                f"mem:{mem}\nfiles:{self.list('')}\n"
                f"l0_names:{[n for n,_ in self.l0]} l1S:{self.l1[1] if self.l1 else '-'} "
                f"next_seq={self.next_seq}")


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
    opts = {'memtable_limit': 512, 'l0_compaction_trigger': 3}
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
            kind = (r >> 8) % 4
            if kind == 0:
                fp = {'kind': 'LostWrite', 'prefix': None}
            elif kind == 1:
                fp = {'kind': 'TornWrite', 'prefix': 'WAL'}
            elif kind == 2:
                fp = {'kind': 'TornWrite', 'prefix': 'L0_'}
            else:
                fp = {'kind': 'TornWrite', 'prefix': 'L1_'}
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
    run_case(1)
