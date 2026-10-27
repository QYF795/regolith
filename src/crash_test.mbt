// crash_test.mbt
//
// M2 §8: the deterministic crash-consistency suite. For each of 200 seeds a
// 40-step random workload runs against a FailpointStorage-backed Db. Steps
// mutate the database (single writes or atomic batches), flush, or simulate
// a crash: plain power loss (the Db is dropped mid-write), or a fault
// injected into the WAL / table write path (LostWrite on the WAL seal,
// TornWrite on the WAL seal, TornWrite on an L0 table write).
//
// After a crash the Db is reopened on the same storage and its full state
// must equal the model replayed over *some* prefix of the operation log —
// the LSM invariant "recovered state = checkpoint ∪ one WAL prefix"
// (docs/acceptance.md §8). Sequence numbers are exactly 1..n in op order, so
// replaying the first s ops models a crash that persisted exactly the first
// s writes. A batch counts as a single op, so no valid prefix may split it —
// the suite proves batch atomicity the same way it proves single-write
// atomicity.
//
// The model is an append-only log of *persisted* writes: flush and
// compaction are invisible to it, and after a crash the ops lost in the
// crash are dropped from the log, so every non-crash step is followed by an
// exact check against the surviving log.

struct Op {
  entries : Array[(Bytes, Option[Bytes])]
}

fn next_rand(rng : Ref[UInt64]) -> UInt64 {
  let mut x = rng.val
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  rng.val = x
  x
}

/// The model state after the first `s` ops. One op is one prefix boundary:
/// a batch counts as a single op, so no prefix may split it (atomicity).
fn replay(ops : Array[Op], s : Int) -> @hashmap.HashMap[Bytes, Bytes] {
  let m : @hashmap.HashMap[Bytes, Bytes] = @hashmap.HashMap([], capacity=16)
  for i = 0; i < s; i = i + 1 {
    for j = 0; j < ops[i].entries.length(); j = j + 1 {
      let (key, value) = ops[i].entries[j]
      match value {
        Some(v) => m.set(key, v)
        None => m.remove(key)
      }
    }
  }
  m
}

/// The database's full live state.
fn snapshot(db : Db) -> @hashmap.HashMap[Bytes, Bytes] raise DbError {
  let m : @hashmap.HashMap[Bytes, Bytes] = @hashmap.HashMap([], capacity=16)
  let it = db.scan()
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        Some(v) => m.set(e.key, v)
        None => ()
      }
    }
  }
  match it.error() {
    Some(err) => raise err
    None => ()
  }
  m
}

fn maps_equal(
  a : @hashmap.HashMap[Bytes, Bytes],
  b : @hashmap.HashMap[Bytes, Bytes]
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for (k, v) in a.iter() {
    match b.get(k) {
      Some(v2) => {
        if v != v2 {
          return false
        }
      }
      None => return false
    }
  }
  true
}

fn diag(msg : String) -> Unit {
  @fs.write_bytes_to_file("crash-diag.txt", @utf8.encode(msg)) catch {
    _ => ()
  }
}

fn map_to_string(m : @hashmap.HashMap[Bytes, Bytes]) -> String {
  let pairs : Array[(Int, Int)] = []
  for (k, v) in m.iter() {
    pairs.push((k[0].to_int(), v[0].to_int()))
  }
  pairs.sort()
  let mut s = "["
  for i = 0; i < pairs.length(); i = i + 1 {
    if i > 0 {
      s = s + ","
    }
    s = s + "\{pairs[i].0}:\{pairs[i].1}"
  }
  s + "]"
}

fn entry_to_string(e : Entry) -> String {
  let v = match e.value {
    Some(val) => "=\{val[0].to_int()}"
    None => "=tomb"
  }
  "\{e.key[0].to_int()}\{v}@\{e.seq}"
}

fn dump_db(db : Db) -> String raise DbError {
  let l1 = match db.l1_name.val {
    Some(n) => n
    None => "None"
  }
  let mut s =
    "mem_bytes=\{db.memtable.size_bytes()} wal=\{db.wal.length()} l0=\{db.l0_names.val.length()} l1=\{l1}\nmem:"
  let mi = db.memtable.iter()
  while true {
    match mi.peek() {
      None => break
      Some(e) => {
        s = s + entry_to_string(e) + " "
        mi.advance()
      }
    }
  }
  s = s + "\nfiles:"
  for f in list(db.storage, "") {
    s = s + f + " "
  }
  s
}

fn ops_to_string(ops : Array[Op]) -> String {
  let mut s = ""
  for i = 0; i < ops.length(); i = i + 1 {
    if i > 0 {
      s = s + " "
    }
    s = s + "\{i}:"
    for j = 0; j < ops[i].entries.length(); j = j + 1 {
      let (key, value) = ops[i].entries[j]
      if j > 0 {
        s = s + ","
      }
      s = s + "\{key[0].to_int()}"
      match value {
        Some(v) => s = s + "=\{v[0].to_int()}"
        None => s = s + "=tomb"
      }
    }
  }
  s
}

/// No crash happened: the state must equal the full model exactly.
fn check_exact(ops : Array[Op], db : Db, ctx : String) -> Unit raise DbError {
  let want = replay(ops, ops.length())
  let got = snapshot(db)
  if !maps_equal(want, got) {
    diag("EXACT FAIL \{ctx}\nops: \{ops_to_string(ops)}\nwant: \{map_to_string(want)}\ngot:  \{map_to_string(got)}\n\{dump_db(db)}\n")
    raise DbError::Fault("state mismatch (\{ctx})")
  }
}

/// A crash happened: the state must equal the model at *some* op boundary.
/// Returns the largest such boundary — the ops the crash did not lose.
fn check_prefix(ops : Array[Op], db : Db, ctx : String) -> Int raise DbError {
  let got = snapshot(db)
  let mut s = ops.length()
  while s >= 0 {
    if maps_equal(replay(ops, s), got) {
      return s
    }
    s = s - 1
  }
  diag("PREFIX FAIL \{ctx}\nops: \{ops_to_string(ops)}\ngot:  \{map_to_string(got)}\n")
  raise DbError::Fault("recovered state is not a prefix (\{ctx})")
}

/// Drops the ops a crash lost: the model tracks the persisted log, so after
/// recovery it is truncated to the boundary the recovered state matched.
fn truncate_ops(ops : Array[Op], s : Int) -> Array[Op] {
  let kept : Array[Op] = []
  for i = 0; i < s; i = i + 1 {
    kept.push(ops[i])
  }
  kept
}

fn run_case(seed : UInt64) -> Unit raise DbError {
  let fp = FailpointStorage::new()
  let opts = Options::default()
    .with_memtable_limit(512)
    .with_compaction_trigger(3)
  let mut db = Db::open_with_options(Storage::Failpoint(fp), opts)
  let mut ops : Array[Op] = []
  let rng = Ref(seed)
  for step = 0; step < 40; step = step + 1 {
    let r = next_rand(rng)
    let key = Bytes::from_array([((r >> 4) % 8).to_int().to_byte()])
    let op = (r % 12).to_int()
    if op < 5 {
      // put
      let value = Bytes::from_array([((r >> 8) % 256).to_int().to_byte()])
      db.put(key, value)
      ops.push({ entries: [(key, Some(value))] })
    } else if op < 7 {
      // delete
      db.delete(key)
      ops.push({ entries: [(key, None)] })
    } else if op == 7 {
      // batch: two writes, one atomic prefix boundary
      let key2 = Bytes::from_array([(key[0].to_int() ^ 1).to_byte()])
      let v1 = Bytes::from_array([((r >> 8) % 256).to_int().to_byte()])
      let v2 = Bytes::from_array([((r >> 16) % 256).to_int().to_byte()])
      db.write(WriteBatch::new().put(key, v1).put(key2, v2))
      ops.push({ entries: [(key, Some(v1)), (key2, Some(v2))] })
    } else if op == 8 {
      // flush (may also trigger compaction — no fault armed)
      db.flush()
    } else if op == 9 {
      // plain crash: drop the Db mid-life; unflushed writes are lost
      db = Db::open_with_options(Storage::Failpoint(fp), opts)
      ops = truncate_ops(
        ops,
        check_prefix(ops, db, "seed=\{seed} step=\{step}"),
      )
    } else {
      // fault crash: arm a write fault, flush into it, drop, reopen
      db.put(key, b"x")
      ops.push({ entries: [(key, Some(b"x"))] })
      let kind = (r >> 8) % 4
      if kind == 0 {
        fp.arm(FaultKind::LostWrite)
      } else if kind == 1 {
        fp.arm_on(FaultKind::TornWrite, "WAL")
      } else if kind == 2 {
        fp.arm_on(FaultKind::TornWrite, "L0_")
      } else {
        fp.arm_on(FaultKind::TornWrite, "L1_")
      }
      // The fault fires on the next matching write (the flush's WAL seal or
      // table write); a flush that never reaches the armed file simply
      // succeeds and the crash still counts as a plain one.
      let _err = try {
        db.flush()
        None
      } catch {
        e => Some(e)
      }
      fp.disarm()
      db = Db::open_with_options(Storage::Failpoint(fp), opts)
      ops = truncate_ops(
        ops,
        check_prefix(ops, db, "seed=\{seed} step=\{step}"),
      )
    }
    if op < 9 {
      check_exact(ops, db, "seed=\{seed} step=\{step}")
    }
  }
}

test "crash consistency: 200 seeds x 40 steps" {
  for i = 0; i < 200; i = i + 1 {
    run_case(i.to_uint64() + 1UL)
  }
}
