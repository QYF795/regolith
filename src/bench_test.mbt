// bench_test.mbt
//
// Performance benchmarks for the whole engine surface. Run with
//
//   moon bench --target js | wasm-gc | native
//
// `moon test` skips these (injection-style bench tests only run under
// `moon bench`). Every benchmark works on an in-memory database so the
// numbers measure the engine, not the disk. Workloads are deterministic:
// fixed-width keys keep lexicographic order == numeric order, values are
// 64-byte blobs. See docs/bench.md for how to read the output.

const N_KEYS : Int = 2_000
const VAL_LEN : Int = 64

/// "k00000"-style key: fixed width so lexicographic == numeric order.
fn bench_key(i : Int) -> Bytes {
  let s = i.to_string()
  let mut k = "k"
  for _j = 0; _j < 5 - s.length(); _j = _j + 1 {
    k = k + "0"
  }
  @utf8.encode(k + s)
}

fn bench_value() -> Bytes {
  Bytes::make(VAL_LEN, 0x42)
}

///|
test "bench put into memtable (2000 x 64B)" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  let mut i = 0
  it.bench(fn() {
    try {
      db.put(bench_key(i), bench_value())
      i = i + 1
      if i >= N_KEYS {
        i = 0
      }
    } catch {
      _ => ()
    }
  })
  db.close()
}

///|
test "bench get from memtable (2000 x 64B)" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  for i = 0; i < N_KEYS; i = i + 1 {
    db.put(bench_key(i), bench_value())
  }
  let mut i = 0
  it.bench(fn() {
    try {
      it.keep(db.get(bench_key(i)))
    } catch {
      _ => ()
    }
    i = i + 1
    if i >= N_KEYS {
      i = 0
    }
  })
  db.close()
}

///|
test "bench get from L0 sstable (2000 x 64B)" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  for i = 0; i < N_KEYS; i = i + 1 {
    db.put(bench_key(i), bench_value())
  }
  db.flush() // data now lives in one L0 table; every get misses the memtable
  let mut i = 0
  it.bench(fn() {
    try {
      it.keep(db.get(bench_key(i)))
    } catch {
      _ => ()
    }
    i = i + 1
    if i >= N_KEYS {
      i = 0
    }
  })
  db.close()
}

///|
test "bench get from L2 sstable (2000 x 64B)" (it : @bench.T) {
  let opts = @QYF795/regolith.Options::default().with_l2_size_trigger(65_536)
  let db = @QYF795/regolith.Db::open_with_options(
    @QYF795/regolith.Storage::Memory(@QYF795/regolith.MemoryStorage::new()),
    opts,
  )
  for i = 0; i < N_KEYS; i = i + 1 {
    db.put(bench_key(i), bench_value())
  }
  db.flush()
  db.compact()
  db.compact_l2() // bottom level; reads take the leveled path directly
  let mut i = 0
  it.bench(fn() {
    try {
      it.keep(db.get(bench_key(i)))
    } catch {
      _ => ()
    }
    i = i + 1
    if i >= N_KEYS {
      i = 0
    }
  })
  db.close()
}

///|
test "bench scan 2000 entries (memtable + L0 merge)" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  for i = 0; i < N_KEYS; i = i + 1 {
    db.put(bench_key(i), bench_value())
  }
  db.flush()
  // A second generation on top: the scan really merges two streams.
  for i = 0; i < N_KEYS; i = i + 2 {
    db.put(bench_key(i), bench_value())
  }
  it.bench(fn() {
    let iter = db.scan()
    let mut n = 0
    while true {
      match iter.next() {
        None => break
        Some(_) => n = n + 1
      }
    }
    it.keep(n)
  })
  db.close()
}

///|
test "bench WriteBatch 500 puts" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  let mut base = 0
  it.bench(fn() {
    try {
      let mut wb = @QYF795/regolith.WriteBatch::new()
      for j = 0; j < 500; j = j + 1 {
        wb = wb.put(bench_key(base + j), bench_value())
      }
      db.write(wb)
      base = base + 500
      if base >= N_KEYS {
        base = 0
      }
    } catch {
      _ => ()
    }
  })
  db.close()
}

///|
test "bench compact L1 merge (2000 x 64B)" (it : @bench.T) {
  let db = @QYF795/regolith.Db::open_memory()
  for i = 0; i < N_KEYS; i = i + 1 {
    db.put(bench_key(i), bench_value())
  }
  db.flush()
  db.compact() // one L1 table now holds everything
  it.bench(fn() {
    try {
      // A fresh L0 on top, then the merge: rewriting the L1 dominates,
      // which is the honest steady-state compaction cost.
      db.put(bench_key(0), bench_value())
      db.flush()
      db.compact()
    } catch {
      _ => ()
    }
  })
  db.close()
}
