// soak_test.mbt
//
// Large-scale soak: 50,000 deterministic random operations (60% put / 15%
// delete / 25% get) over an in-memory database, cross-checked against a
// simple model, with periodic flushes, L1/L2 compactions and full
// close/reopen cycles. The crash suite proves crash consistency; this
// suite proves sustained mixed workloads converge — every get matches the
// model, every reopen rebuilds the same state, tombstones stay suppressed.

const SOAK_KEYS : Int = 1_000
const SOAK_OPS : Int = 50_000
const SOAK_SEED : UInt = 0x9E3779B9

/// xorshift32 step — same generator family as MemTable::roll_levels, so
/// the workload is deterministic across runs and backends.
fn soak_xorshift(seed : UInt) -> UInt {
  let mut x = seed
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  x
}

/// "0000".."0999": fixed width keeps lexicographic order == numeric order.
fn soak_key(i : Int) -> Bytes {
  let s = i.to_string()
  let mut k = ""
  for _j = 0; _j < 4 - s.length(); _j = _j + 1 {
    k = k + "0"
  }
  @utf8.encode(k + s)
}

/// "v<op>": a value unique to each write, so last-write-wins is checked
/// against the exact expected bytes.
fn soak_value(op : Int) -> Bytes {
  @utf8.encode("v" + op.to_string())
}

/// Walks a full scan against the model: the scan must yield exactly the
/// live model keys in ascending order with matching values.
fn check_scan(db : Db, keys : FixedArray[Bytes], model : FixedArray[Option[Bytes]]) -> Unit raise {
  let it = db.scan()
  let mut mi = 0
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        None => () // tombstones are suppressed by the merge iterator
        Some(v) => {
          while mi < SOAK_KEYS && model[mi] is None {
            mi = mi + 1
          }
          assert_true(mi < SOAK_KEYS, msg="soak: scan yielded more keys than the model holds")
          assert_true(e.key == keys[mi], msg="soak: scan key order mismatch")
          assert_true(model[mi] == Some(v), msg="soak: scan value mismatch")
          mi = mi + 1
        }
      }
    }
  }
  assert_true(it.error() is None, msg="soak: scan reported an error")
  while mi < SOAK_KEYS {
    assert_true(model[mi] is None, msg="soak: scan missed a live model key")
    mi = mi + 1
  }
}

test "soak 50000 random ops against model with flush compact compact_l2 reopen" {
  let keys : FixedArray[Bytes] = FixedArray::makei(SOAK_KEYS, fn(i) { soak_key(i) })
  let model : FixedArray[Option[Bytes]] = FixedArray::make(SOAK_KEYS, None)
  let storage = MemoryStorage::new()
  let mut db = Db::open_with_options(Storage::Memory(storage), Options::default())
  let mut seed : UInt = SOAK_SEED
  for op = 0; op < SOAK_OPS; op = op + 1 {
    seed = soak_xorshift(seed)
    let i = (seed % 1000U).reinterpret_as_int()
    let k = keys[i]
    let r = (seed % 100U).reinterpret_as_int() // 0..99: 60 put / 15 del / 25 get
    if r < 60 {
      db.put(k, soak_value(op))
      model[i] = Some(soak_value(op))
    } else if r < 75 {
      db.delete(k)
      model[i] = None
    } else {
      match db.get(k) {
        None => assert_true(model[i] is None, msg="soak: get None but model has a value")
        Some(None) => assert_true(model[i] is None, msg="soak: get tombstone but model has a value")
        Some(Some(v)) => assert_true(model[i] == Some(v), msg="soak: get value mismatch")
      }
    }
    if op % 500 == 499 {
      db.flush()
    }
    if op % 5_000 == 4_999 {
      db.compact()
    }
    if op % 10_000 == 4_999 {
      // L1 → L2 selective bottom merge (tombstones suppressed): runs right
      // after the L0 → L1 compaction on the same tick, so the reopen five
      // thousand ops later must rebuild state from L2 tables alone.
      db.compact_l2()
    }
    if op % 10_000 == 9_999 {
      // Full close/reopen: recovery must rebuild the exact same state from
      // tables + WAL alone.
      db.close()
      db = Db::open_with_options(Storage::Memory(storage), Options::default())
      check_scan(db, keys, model)
    }
  }
  check_scan(db, keys, model)
  db.close()
}

/// Snapshot soak: while the live db keeps writing, flushing and compacting,
/// every active snapshot must keep answering with the exact state that
/// existed at its creation. The model records a full key-value copy at each
/// snapshot point; random probes compare snapshot scans and gets against it.
const SNAP_KEYS : Int = 64
const SNAP_OPS : Int = 10_000

/// Full-scan check of one snapshot against its frozen model copy.
fn check_snap_scan(
  snap : Snapshot,
  keys : FixedArray[Bytes],
  model : FixedArray[Option[Bytes]]
) -> Unit raise {
  let it = snap.scan()
  let mut mi = 0
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        None => ()
        Some(v) => {
          while mi < SNAP_KEYS && model[mi] is None {
            mi = mi + 1
          }
          assert_true(mi < SNAP_KEYS, msg="snap soak: scan yielded more keys than the frozen model")
          assert_true(e.key == keys[mi], msg="snap soak: scan key order mismatch")
          assert_true(model[mi] == Some(v), msg="snap soak: scan value mismatch")
          mi = mi + 1
        }
      }
    }
  }
  assert_true(it.error() is None, msg="snap soak: snapshot scan reported an error")
  while mi < SNAP_KEYS {
    assert_true(model[mi] is None, msg="snap soak: scan missed a frozen model key")
    mi = mi + 1
  }
}

test "snapshot soak: live snapshots stay frozen across random ops" {
  let keys : FixedArray[Bytes] = FixedArray::makei(SNAP_KEYS, fn(i) { soak_key(i) })
  let model : FixedArray[Option[Bytes]] = FixedArray::make(SNAP_KEYS, None)
  let db = Db::open_memory()
  // (snapshot handle, full model copy frozen at creation)
  let snaps : Array[(Snapshot, FixedArray[Option[Bytes]])] = []
  let mut seed : UInt = 0x1234ABCD
  for op = 0; op < SNAP_OPS; op = op + 1 {
    seed = soak_xorshift(seed)
    let i = (seed % 64U).reinterpret_as_int()
    let r = (seed % 100U).reinterpret_as_int()
    // 60 put / 10 del / 4 snapshot / 4 close / 22 probe
    if r < 60 {
      db.put(keys[i], soak_value(op))
      model[i] = Some(soak_value(op))
    } else if r < 70 {
      db.delete(keys[i])
      model[i] = None
    } else if r < 74 && snaps.length() < 8 {
      let frozen : FixedArray[Option[Bytes]] = FixedArray::make(SNAP_KEYS, None)
      for j = 0; j < SNAP_KEYS; j = j + 1 {
        frozen[j] = model[j]
      }
      snaps.push((db.snapshot(), frozen))
    } else if r < 78 && snaps.length() > 0 {
      let idx = (seed % 8U).reinterpret_as_int() % snaps.length()
      snaps[idx].0.close()
      // swap-remove keeps the array compact without an O(n) shift
      snaps[idx] = snaps[snaps.length() - 1]
      let _ = snaps.pop()
    } else if snaps.length() > 0 {
      let idx = (seed % 8U).reinterpret_as_int() % snaps.length()
      let (snap, frozen) = snaps[idx]
      check_snap_scan(snap, keys, frozen)
      for _p = 0; _p < 8; _p = _p + 1 {
        seed = soak_xorshift(seed)
        let ki = (seed % 64U).reinterpret_as_int()
        match snap.get(keys[ki]) {
          None => assert_true(frozen[ki] is None, msg="snap soak: frozen get None mismatch")
          Some(None) => assert_true(frozen[ki] is None, msg="snap soak: frozen get tombstone mismatch")
          Some(Some(v)) => assert_true(frozen[ki] == Some(v), msg="snap soak: frozen get value mismatch")
        }
      }
    }
    if op % 500 == 499 {
      db.flush()
    }
    if op % 2_500 == 2_499 {
      db.compact()
    }
    if op % 5_000 == 4_999 {
      db.compact_l2()
    }
  }
  for j = 0; j < snaps.length(); j = j + 1 {
    snaps[j].0.close()
  }
  // Final check against the live db (check_scan is hard-wired to SOAK_KEYS).
  for j = 0; j < SNAP_KEYS; j = j + 1 {
    match db.get(keys[j]) {
      None => assert_true(model[j] is None, msg="snap soak: final get None mismatch")
      Some(None) => assert_true(model[j] is None, msg="snap soak: final get tombstone mismatch")
      Some(Some(v)) => assert_true(model[j] == Some(v), msg="snap soak: final get value mismatch")
    }
  }
  db.close()
}
