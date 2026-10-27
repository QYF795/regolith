// db_test.mbt
//
// Engine-level tests: the write path, flush, recovery, scan and compaction.
// These cover the M1 acceptance items (§2-§6); the crash-consistency suite
// built on FailpointStorage lives in crash_test.mbt (M2, §8).

test "db put get delete in memory" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  assert_true(db.get(b"a") == Some(Some(b"1")))
  assert_true(db.get(b"b") == Some(Some(b"2")))
  db.delete(b"a")
  assert_true(db.get(b"a") == Some(None))
  assert_true(db.get(b"c") is None)
}

test "db flush then reopen recovers data" {
  let ms = MemoryStorage::new()
  let db1 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db1.put(b"a", b"1")
  db1.put(b"b", b"2")
  db1.flush()
  db1.put(b"c", b"3")
  db1.flush()
  db1.delete(b"a")
  db1.flush()
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.get(b"a") == Some(None))
  assert_true(db2.get(b"b") == Some(Some(b"2")))
  assert_true(db2.get(b"c") == Some(Some(b"3")))
}

test "db wal replay covers sealed-but-untabled writes" {
  let ms = MemoryStorage::new()
  let db1 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db1.put(b"a", b"1")
  db1.flush()
  db1.put(b"b", b"2")
  db1.flush()
  db1.put(b"c", b"3")
  // Simulate a crash right after the WAL seal but before the table write:
  // the WAL file holds the record while no table covers it.
  write(Storage::Memory(ms), "WAL", db1.wal.encode())
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.get(b"a") == Some(Some(b"1")))
  assert_true(db2.get(b"b") == Some(Some(b"2")))
  assert_true(db2.get(b"c") == Some(Some(b"3")))
}

test "db scan returns ordered live entries" {
  let db = Db::open_memory()
  db.put(b"b", b"2")
  db.put(b"a", b"1")
  db.put(b"c", b"3")
  let keys : Array[Bytes] = []
  let it = db.scan()
  while true {
    match it.next() {
      None => break
      Some(e) => keys.push(e.key)
    }
  }
  assert_true(it.error() is None)
  assert_true(keys.length() == 3)
  assert_true(keys[0] == b"a")
  assert_true(keys[1] == b"b")
  assert_true(keys[2] == b"c")
}

test "db scan merges memtable and tables" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  db.put(b"a", b"old")
  db.flush()
  db.put(b"a", b"new")
  db.put(b"b", b"2")
  let it = db.scan()
  let kvs : Array[(Bytes, Bytes)] = []
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        Some(v) => kvs.push((e.key, v))
        None => ()
      }
    }
  }
  assert_true(kvs.length() == 2)
  assert_true(kvs[0].0 == b"a" && kvs[0].1 == b"new")
  assert_true(kvs[1].0 == b"b" && kvs[1].1 == b"2")
}

test "db auto flush on memtable limit" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_memtable_limit(256)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  for i = 0; i < 20; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    db.put(k, b"value")
  }
  assert_true(db.stats().l0_files > 0)
  db.flush()
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  for i = 0; i < 20; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    assert_true(db2.get(k) == Some(Some(b"value")))
  }
}

test "db compaction merges l0 into l1" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.flush()
  db.put(b"b", b"2")
  db.flush()
  let st = db.stats()
  assert_true(st.l1_files == 1)
  assert_true(st.l0_files == 0)
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.get(b"a") == Some(Some(b"1")))
  assert_true(db2.get(b"b") == Some(Some(b"2")))
}

test "db compaction keeps newest value across tables" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(3)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"v1")
  db.flush()
  db.put(b"a", b"v2")
  db.flush()
  db.delete(b"a")
  db.flush() // triggers compaction with the tombstone on top
  let st = db.stats()
  assert_true(st.l0_files == 0)
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.get(b"a") is None)
}

test "db recovery drops stale l0 covered by l1" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  db.flush()
  // Simulate a compaction that wrote L1_2.sst but crashed before deleting
  // the old L0 tables: the L1 subsumes every seq <= 2 entry.
  let builder = SstBuilder::new()
  builder.add({ key: b"a", seq: 1UL, value: Some(b"1") })
  builder.add({ key: b"b", seq: 2UL, value: Some(b"2") })
  write(Storage::Memory(ms), "L1_2.sst", builder.finish())
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.stats().l0_files == 0)
  assert_true(db2.stats().l1_files == 1)
  assert_true(db2.get(b"a") == Some(Some(b"1")))
  assert_true(db2.get(b"b") == Some(Some(b"2")))
}

test "db recovery drops stale l1" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  db.put(b"a", b"1")
  db.flush()
  let old_b = SstBuilder::new()
  old_b.add({ key: b"a", seq: 1UL, value: Some(b"1") })
  write(Storage::Memory(ms), "L1_1.sst", old_b.finish())
  let new_b = SstBuilder::new()
  new_b.add({ key: b"a", seq: 1UL, value: Some(b"1") })
  new_b.add({ key: b"b", seq: 2UL, value: Some(b"2") })
  write(Storage::Memory(ms), "L1_2.sst", new_b.finish())
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.stats().l1_files == 1)
  assert_true(db2.get(b"b") == Some(Some(b"2")))
}

test "db recovery skips stale wal records covered by l1" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  db.flush()
  let builder = SstBuilder::new()
  builder.add({ key: b"a", seq: 1UL, value: Some(b"1") })
  builder.add({ key: b"b", seq: 2UL, value: Some(b"2") })
  write(Storage::Memory(ms), "L1_2.sst", builder.finish())
  // A stale WAL holding seq 1 for key "a" must not override the table.
  let stale = Wal::new()
  stale.append(b"a", Some(b"stale"), 1UL)
  write(Storage::Memory(ms), "WAL", stale.encode())
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.get(b"a") == Some(Some(b"1")))
}

test "db seq continues after reopen" {
  let ms = MemoryStorage::new()
  let db1 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db1.put(b"a", b"old")
  db1.put(b"b", b"2")
  db1.flush()
  // Reopen and keep writing: new writes must not reuse table sequence
  // numbers, or an equal-seq entry would shadow the newer one in a scan.
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db2.put(b"a", b"new")
  db2.flush()
  let db3 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db3.get(b"a") == Some(Some(b"new")))
  let kvs : Array[(Bytes, Bytes)] = []
  let it = db3.scan()
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        Some(v) => kvs.push((e.key, v))
        None => ()
      }
    }
  }
  assert_true(kvs.length() == 2)
  assert_true(kvs[0].0 == b"a" && kvs[0].1 == b"new")
  assert_true(kvs[1].0 == b"b" && kvs[1].1 == b"2")
}

test "db recovery drops torn tables" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  db.put(b"a", b"1")
  db.flush()
  // Truncate the L0 table in place, then reopen.
  let bytes = read(Storage::Memory(ms), "L0_000000.sst").unwrap()
  write(Storage::Memory(ms), "L0_000000.sst", bytes[0:bytes.length() - 1].to_owned())
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  assert_true(db2.stats().l0_files == 0)
  assert_true(db2.get(b"a") is None)
}

test "db get hits every key in bloom-filtered tables" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_memtable_limit(1024)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  for i = 0; i < 200; i = i + 1 {
    let k = Bytes::from_array([i.to_byte(), (i / 256).to_byte()])
    db.put(k, Bytes::from_array([i.to_byte()]))
  }
  db.flush()
  // All tables now carry bloom filters; every written key must read back.
  for i = 0; i < 200; i = i + 1 {
    let k = Bytes::from_array([i.to_byte(), (i / 256).to_byte()])
    assert_true(db.get(k) == Some(Some(Bytes::from_array([i.to_byte()]))))
  }
  // Absent keys: the filter may say yes (false positive) but get says no.
  for i = 0; i < 50; i = i + 1 {
    let k = Bytes::from_array([(255).to_byte(), i.to_byte()])
    assert_true(db.get(k) is None)
  }
}

test "db scan_prefix returns only keys under the prefix" {
  let ms = MemoryStorage::new()
  let db = Db::open_with_options(Storage::Memory(ms), Options::default())
  // Keys before, inside and after the "app" prefix, across a flush boundary
  // so the merge pulls from both a table and the memtable.
  db.put(b"ant", b"1")
  db.put(b"app1", b"2")
  db.put(b"apple", b"3")
  db.flush()
  db.put(b"app2", b"4")
  db.put(b"apricot", b"5")
  db.put(b"banana", b"6")
  db.delete(b"app1")
  let it = db.scan_prefix(b"app")
  let keys : Array[Bytes] = []
  while true {
    match it.next() {
      None => break
      Some(e) => keys.push(e.key)
    }
  }
  assert_true(it.error() is None)
  // The deleted "app1" is suppressed; "apricot"/"banana" are outside.
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"app2")
  assert_true(keys[1] == b"apple")
  // An empty prefix matches every key: the whole store comes back.
  let all = db.scan_prefix(b"")
  let mut total = 0
  while true {
    match all.next() {
      None => break
      Some(_) => total = total + 1
    }
  }
  assert_true(total == 5)
}

test "db scan_prefix reads from tables after reopen" {
  let ms = MemoryStorage::new()
  let db1 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db1.put(b"user:1", b"alice")
  db1.put(b"user:2", b"bob")
  db1.put(b"note:1", b"x")
  db1.flush()
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  let it = db2.scan_prefix(b"user:")
  match it.next() {
    Some(e) => assert_true(e.key == b"user:1" && e.value == Some(b"alice"))
    None => assert_true(false)
  }
  match it.next() {
    Some(e) => assert_true(e.key == b"user:2" && e.value == Some(b"bob"))
    None => assert_true(false)
  }
  assert_true(it.next() is None)
  assert_true(it.error() is None)
}

fn collect_range(it : RangeIterator) -> Array[Bytes] raise DbError {
  let keys : Array[Bytes] = []
  while true {
    match it.next() {
      None => break
      Some(e) => keys.push(e.key)
    }
  }
  match it.error() {
    Some(err) => raise err
    None => ()
  }
  keys
}

test "db scan_range returns keys within [start, end)" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  db.put(b"bb", b"2")
  db.put(b"c", b"3")
  db.put(b"dd", b"4")
  db.put(b"e", b"5")
  // Inclusive start, exclusive end, mixed key lengths.
  let keys = collect_range(db.scan_range(b"b", Some(b"dd")))
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"bb")
  assert_true(keys[1] == b"c")
  // A key equal to the end bound is excluded.
  let keys2 = collect_range(db.scan_range(b"a", Some(b"bb")))
  assert_true(keys2.length() == 1)
  assert_true(keys2[0] == b"a")
}

test "db scan_range with open upper bound" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  db.put(b"bb", b"2")
  db.put(b"c", b"3")
  db.put(b"dd", b"4")
  let keys = collect_range(db.scan_range(b"bb", None))
  assert_true(keys.length() == 3)
  assert_true(keys[0] == b"bb")
  assert_true(keys[1] == b"c")
  assert_true(keys[2] == b"dd")
  // start beyond every key, and an empty range [x, x).
  assert_true(collect_range(db.scan_range(b"z", None)).is_empty())
  assert_true(collect_range(db.scan_range(b"c", Some(b"c"))).is_empty())
}

test "db scan_range skips tombstones and reads across reopen" {
  let ms = MemoryStorage::new()
  let db1 = Db::open_with_options(Storage::Memory(ms), Options::default())
  db1.put(b"a", b"1")
  db1.put(b"b", b"2")
  db1.put(b"c", b"3")
  db1.flush()
  db1.delete(b"b")
  // The tombstone is still in the memtable: the range skips it.
  let keys = collect_range(db1.scan_range(b"a", Some(b"d")))
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"a")
  assert_true(keys[1] == b"c")
  // After a flush and reopen the tombstone lives in an L0 table instead;
  // the range still skips it.
  db1.flush()
  let db2 = Db::open_with_options(Storage::Memory(ms), Options::default())
  let keys2 = collect_range(db2.scan_range(b"a", Some(b"d")))
  assert_true(keys2.length() == 2)
  assert_true(keys2[0] == b"a")
  assert_true(keys2[1] == b"c")
}

test "db scan_prefix all-FF prefix falls back to prefix check" {
  let db = Db::open_memory()
  db.put(Bytes::from_array([(0xFF).to_byte(), (0xFE).to_byte()]), b"1")
  db.put(Bytes::from_array([(0xFF).to_byte(), (0xFF).to_byte(), (1).to_byte()]), b"2")
  db.put(Bytes::from_array([(0xFF).to_byte(), (0xFF).to_byte()]), b"3")
  db.put(b"x", b"4")
  // A prefix of all 0xFF bytes has no finite successor: the upper bound
  // falls back to a per-key prefix check.
  let keys = collect_range(db.scan_prefix(Bytes::from_array([(0xFF).to_byte(), (0xFF).to_byte()])))
  assert_true(keys.length() == 2)
  assert_true(keys[0] == Bytes::from_array([(0xFF).to_byte(), (0xFF).to_byte()]))
  assert_true(keys[1] == Bytes::from_array([(0xFF).to_byte(), (0xFF).to_byte(), (1).to_byte()]))
}
