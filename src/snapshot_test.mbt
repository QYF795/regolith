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

fn collect_entries(it : MergeIterator) -> Array[(Bytes, Option[Bytes])] raise DbError {
  let out : Array[(Bytes, Option[Bytes])] = []
  while true {
    match it.next() {
      None => break
      Some(e) => out.push((e.key, e.value))
    }
  }
  match it.error() {
    Some(err) => raise err
    None => ()
  }
  out
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

test "compaction deletes merged tables immediately while snapshots read from memory" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.flush()
  db.put(b"b", b"2")
  db.flush()
  assert_true(db.stats().l1_files == 1)
  let held = db.l1_tables.val[0].name
  let snap = db.snapshot()
  assert_true(list(db.storage, "").contains(held))
  // Two more flushes (rewriting the same keys) trigger an L1 compaction:
  // the old L1 is merged away and its file deleted right away — the
  // snapshot holds the parsed bytes in memory and never touches the file.
  db.put(b"a", b"3")
  db.flush()
  db.put(b"b", b"4")
  db.flush()
  assert_true(!list(db.storage, "").contains(held), msg="merged table file must be deleted immediately")
  assert_true(snap.get(b"a") == Some(Some(b"1")))
  assert_true(snap.get(b"b") == Some(Some(b"2")))
  snap.close()
}

test "multiple snapshots are independent in-memory views" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.flush()
  db.put(b"b", b"2")
  db.flush()
  let snap1 = db.snapshot()
  let snap2 = db.snapshot()
  db.put(b"a", b"3")
  db.flush()
  db.put(b"b", b"4")
  db.flush()
  // Both snapshots keep serving the frozen view after the tables they
  // captured were merged away and deleted.
  assert_true(snap1.get(b"a") == Some(Some(b"1")))
  assert_true(snap2.get(b"a") == Some(Some(b"1")))
  assert_true(snap1.get(b"b") == Some(Some(b"2")))
  assert_true(snap2.get(b"b") == Some(Some(b"2")))
  assert_true(db.get(b"a") == Some(Some(b"3")))
  snap1.close()
  snap2.close()
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
  // A closed snapshot still serves reads from its captured in-memory tables.
  assert_true(snap.get(b"a") == Some(Some(b"1")))
}

// Acceptance rejection regression (2026-11): holding a snapshot deferred the
// physical deletion of tables consumed by compaction. A live snapshot kept
// files on disk that recovery could not classify — reopening resurrected
// deleted keys and diverged get from scan.

test "a held snapshot cannot resurrect deleted keys across reopen (L2 merge)" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  db.flush()
  db.put(b"c", b"3")
  db.flush() // 2nd flush triggers compact -> L1(a,b,c)
  db.compact_l2() // -> L2(a@1,b@2,c@3)
  let snap = db.snapshot()
  // Delete while the snapshot is held, then flush + compact + L2 merge: the
  // tombstone is suppressed and the old L2 is consumed. If the consumed
  // file lingers (pinned), the next open sees a stale copy of `a`.
  db.delete(b"a")
  db.flush()
  db.compact() // L1(tomb a)
  db.compact_l2() // tomb suppressed -> L2(b,c)
  // The snapshot stays open — a process exiting without close leaves the
  // same files behind.
  let db2 = Db::open_with_options(Storage::Memory(ms), opts)
  assert_true(db2.get(b"a") == None, msg="deleted key resurrected after reopen")
  let entries = collect_entries(db2.scan())
  assert_true(entries.length() == 2, msg="scan must not contain the deleted key")
  assert_true(entries[0] == (b"b", Some(b"2")))
  assert_true(entries[1] == (b"c", Some(b"3")))
  assert_true(snap.get(b"a") == Some(Some(b"1")), msg="snapshot view must stay frozen")
  snap.close()
}

test "get and scan agree across reopen when a snapshot was held across an update" {
  let ms = MemoryStorage::new()
  let opts = Options::default().with_compaction_trigger(2)
  let db = Db::open_with_options(Storage::Memory(ms), opts)
  db.put(b"a", b"1")
  db.put(b"b", b"2")
  db.flush()
  db.put(b"c", b"3")
  db.flush() // 2nd flush triggers compact -> L1(a@1,b@2,c@3)
  let snap = db.snapshot()
  db.put(b"a", b"9") // a@4
  db.flush()
  db.compact() // merges L0 + the overlapping L1 -> L1(a@4,b@2,c@3)
  db.compact_l2() // -> L2(a@4,b@2,c@3)
  let db2 = Db::open_with_options(Storage::Memory(ms), opts)
  // L1 keep-all keeps the pinned stale L1 on disk: get short-circuits to
  // the old value while scan (sequence merge) sees the new one.
  assert_true(db2.get(b"a") == Some(Some(b"9")), msg="get returned a stale value after reopen")
  let entries = collect_entries(db2.scan())
  assert_true(entries[0] == (b"a", Some(b"9")), msg="scan and get must agree")
  assert_true(snap.get(b"a") == Some(Some(b"1")), msg="snapshot view must stay frozen")
  snap.close()
}
