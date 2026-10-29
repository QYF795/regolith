// clicore_test.mbt

test "clicore set get del" {
  let db = @QYF795/regolith.Db::open_memory()
  assert_true(run(db, ["set", "a", "1"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "1")
  assert_true(run(db, ["del", "a"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "(deleted)")
  assert_true(run(db, ["get", "zz"]) == "(not found)")
}

test "clicore scan and stats" {
  let db = @QYF795/regolith.Db::open_memory()
  let _ = run(db, ["set", "b", "2"])
  let _ = run(db, ["set", "a", "1"])
  assert_true(run(db, ["scan"]) == "a=1\nb=2\n")
  // set flushes for durability, so two sets leave two L0 tables.
  assert_true(run(db, ["stats"]).contains("l0: 2 tables"))
}

test "clicore binary keys and values render as hex" {
  let db = @QYF795/regolith.Db::open_memory()
  db.put(
    Bytes::from_array([(0).to_byte(), (0xFF).to_byte()]),
    Bytes::from_array([(0xFE).to_byte()]),
  )
  assert_true(run(db, ["scan"]).contains("0x00ff=0xfe"))
}

test "clicore usage errors" {
  let db = @QYF795/regolith.Db::open_memory()
  assert_true(run(db, []) == "error: no command (try \"help\")")
  assert_true(run(db, ["nope"]) == "error: unknown command nope (try \"help\")")
  assert_true(run(db, ["get"]) == "error: usage: get <key>")
  assert_true(run(db, ["set", "k"]) == "error: usage: set <key> <value>")
}

test "clicore flush and compact" {
  let ms = @QYF795/regolith.MemoryStorage::new()
  let opts = @QYF795/regolith.Options::default().with_compaction_trigger(2)
  let db = @QYF795/regolith.Db::open_with_options(@QYF795/regolith.Storage::Memory(ms), opts)
  let _ = run(db, ["set", "a", "1"])
  assert_true(run(db, ["flush"]) == "ok")
  let _ = run(db, ["set", "b", "2"])
  assert_true(run(db, ["flush"]) == "ok")
  assert_true(db.stats().l1_files == 1)
  assert_true(db.stats().l0_files == 0)
  assert_true(run(db, ["compact"]) == "ok")
  // Manual compaction merges everything into the bottom level.
  assert_true(db.stats().l1_files == 0)
  assert_true(db.stats().l2_files == 1)
  // Entries survive the manual compaction.
  assert_true(run(db, ["get", "a"]) == "1")
  assert_true(run(db, ["get", "b"]) == "2")
}

test "clicore scan_prefix" {
  let db = @QYF795/regolith.Db::open_memory()
  let _ = run(db, ["set", "user:1", "alice"])
  let _ = run(db, ["set", "user:2", "bob"])
  let _ = run(db, ["set", "note:1", "x"])
  assert_true(run(db, ["scan_prefix", "user:"]) == "user:1=alice\nuser:2=bob\n")
  assert_true(run(db, ["scan_prefix", "zz"]) == "")
  assert_true(run(db, ["scan_prefix"]) == "error: usage: scan_prefix <prefix>")
}

test "clicore scan_range" {
  let db = @QYF795/regolith.Db::open_memory()
  let _ = run(db, ["set", "user:1", "alice"])
  let _ = run(db, ["set", "user:2", "bob"])
  let _ = run(db, ["set", "note:1", "x"])
  // "user;" is the first key after the "user:" prefix.
  assert_true(run(db, ["scan_range", "user:", "user;"]) == "user:1=alice\nuser:2=bob\n")
  // An empty end means no upper bound.
  assert_true(run(db, ["scan_range", "note:1", ""]) == "note:1=x\nuser:1=alice\nuser:2=bob\n")
  assert_true(run(db, ["scan_range", "zz", "zzz"]) == "")
  assert_true(run(db, ["scan_range"]) == "error: usage: scan_range <start> <end>")
}

test "clicore batch applies atomically and durably" {
  let db = @QYF795/regolith.Db::open_memory()
  let _ = run(db, ["set", "c", "old"])
  assert_true(run(db, ["batch", "put", "a", "1", "put", "b", "2", "del", "c"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "1")
  assert_true(run(db, ["get", "b"]) == "2")
  assert_true(run(db, ["get", "c"]) == "(deleted)")
  // The batch is one durable unit: the earlier set and the batch each
  // produced one L0 table, nothing more.
  assert_true(run(db, ["stats"]).contains("l0: 2 tables"))
}

test "clicore batch last write wins and usage errors" {
  let db = @QYF795/regolith.Db::open_memory()
  assert_true(run(db, ["batch", "put", "a", "1", "put", "a", "2"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "2")
  assert_true(run(db, ["batch"]) == "error: usage: batch (put <key> <value> | del <key>)...")
  assert_true(run(db, ["batch", "put", "k"]) == "error: batch: put needs <key> <value>")
  assert_true(run(db, ["batch", "del"]) == "error: batch: del needs <key>")
  assert_true(run(db, ["batch", "foo", "k"]) == "error: batch: expected put or del, got foo")
}
