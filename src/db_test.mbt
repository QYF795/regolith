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
