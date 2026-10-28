// snapshot_test.mbt

fn collect_keys(it : MergeIterator) -> Array[Bytes] raise DbError {
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

test "snapshot sees the state at creation while the db advances" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  let snap = db.snapshot()
  db.put(b"a", b"9")
  db.delete(b"b")
  db.put(b"c", b"3")
  assert_true(snap.get(b"a") == Some(Some(b"1")))
  assert_true(snap.get(b"b") == Some(Some(b"2")))
  assert_true(snap.get(b"c") == None)
  assert_true(db.get(b"a") == Some(Some(b"9")))
  assert_true(db.get(b"b") == Some(None))
  assert_true(db.get(b"c") == Some(Some(b"3")))
  snap.close()
}

test "snapshot sees tombstones frozen before creation" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  db.delete(b"gone")
  let snap = db.snapshot()
  assert_true(snap.get(b"gone") == Some(None))
  db.put(b"gone", b"back")
  assert_true(snap.get(b"gone") == Some(None))
  assert_true(db.get(b"gone") == Some(Some(b"back")))
  snap.close()
}

test "snapshot scan prefix and range see the frozen view" {
  let db = Db::open_memory()
  db.put(b"user:1", b"alice")
  db.put(b"user:2", b"bob")
  db.put(b"note:1", b"x")
  let snap = db.snapshot()
  db.put(b"user:1", b"carol")
  db.put(b"user:3", b"dave")
  let keys = collect_range(snap.scan_prefix(b"user:"))
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"user:1")
  assert_true(keys[1] == b"user:2")
  let keys2 = collect_range(snap.scan_range(b"note:1", None))
  assert_true(keys2.length() == 3)
  assert_true(keys2[0] == b"note:1")
  assert_true(keys2[1] == b"user:1")
  assert_true(keys2[2] == b"user:2")
  snap.close()
}

test "snapshot reads survive flush and compaction of the live db" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2).with_l2_size_trigger(20)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  let snap = db.snapshot()
  // The live db advances through flush, L1 compaction and L2 compaction.
  db.flush()
  db.put(b"c", b"3")
  db.put(b"d", b"4")
  db.flush()
  db.compact()
  db.compact_l2()
  db.put(b"a", b"9")
  assert_true(snap.get(b"a") == Some(Some(b"1")))
  assert_true(snap.get(b"b") == Some(Some(b"2")))
  assert_true(snap.get(b"c") == None)
  assert_true(snap.get(b"d") == None)
  let keys = collect_keys(snap.scan())
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"a")
  assert_true(keys[1] == b"b")
  assert_true(db.get(b"a") == Some(Some(b"9")))
  assert_true(db.get(b"d") == Some(Some(b"4")))
  snap.close()
}

test "compaction defers files held by snapshots until close" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.flush()
  db.put(b"b", b"2")
  db.flush()
  assert_true(db.stats().l1_files == 1)
  let snap = db.snapshot()
  let held = match snap.l1_name {
    Some(n) => n
    None => abort("snapshot expected an L1 table")
  }
  assert_true(list(db.storage, "").contains(held))
  // Two more flushes trigger an L1 compaction: the old L1 is merged away
  // but stays on storage because the snapshot pins it.
  db.put(b"c", b"3")
  db.flush()
  db.put(b"d", b"4")
  db.flush()
  assert_true(list(db.storage, "").contains(held))
  assert_true(snap.get(b"a") == Some(Some(b"1")))
  assert_true(snap.get(b"b") == Some(Some(b"2")))
  snap.close()
  // Released: the deferred file is physically gone now.
  assert_true(!list(db.storage, "").contains(held))
}

test "multiple snapshots release independently" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.flush()
  db.put(b"b", b"2")
  db.flush()
  let snap1 = db.snapshot()
  let snap2 = db.snapshot()
  let held = match snap1.l1_name {
    Some(n) => n
    None => abort("snapshot expected an L1 table")
  }
  db.put(b"c", b"3")
  db.flush()
  db.put(b"d", b"4")
  db.flush()
  assert_true(list(db.storage, "").contains(held))
  snap1.close()
  // snap2 still pins the file.
  assert_true(list(db.storage, "").contains(held))
  assert_true(snap2.get(b"a") == Some(Some(b"1")))
  snap2.close()
  assert_true(!list(db.storage, "").contains(held))
}

test "snapshot iterator is a stable handle across writes flush and compact" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2).with_l2_size_trigger(20)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  let snap = db.snapshot()
  let it = snap.scan()
  // Mutate the live db heavily while holding the handle.
  db.put(b"a", b"9")
  db.delete(b"b")
  db.put(b"c", b"3")
  db.flush()
  db.put(b"d", b"4")
  db.flush()
  db.compact()
  db.compact_l2()
  // The handle still yields the frozen view.
  let keys = collect_keys(it)
  assert_true(keys.length() == 2)
  assert_true(keys[0] == b"a")
  assert_true(keys[1] == b"b")
  // The same view is reachable again: pause = stop calling next, resume =
  // open a fresh iterator (or scan_range from the last key) on the snapshot.
  let keys2 = collect_keys(snap.scan())
  assert_true(keys2 == keys)
  snap.close()
}

test "snapshot close is idempotent and reads survive close" {
  let db = Db::open_memory()
  db.put(b"a", b"1")
  let snap = db.snapshot()
  snap.close()
  snap.close()
  // A closed snapshot still serves reads from its pinned in-memory tables.
  assert_true(snap.get(b"a") == Some(Some(b"1")))
}
