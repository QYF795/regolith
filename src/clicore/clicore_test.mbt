// clicore_test.mbt

test "clicore set get del" {
  let db = @regolith.Db::open_memory()
  assert_true(run(db, ["set", "a", "1"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "1")
  assert_true(run(db, ["del", "a"]) == "ok")
  assert_true(run(db, ["get", "a"]) == "(deleted)")
  assert_true(run(db, ["get", "zz"]) == "(not found)")
}

test "clicore scan and stats" {
  let db = @regolith.Db::open_memory()
  let _ = run(db, ["set", "b", "2"])
  let _ = run(db, ["set", "a", "1"])
  assert_true(run(db, ["scan"]) == "a=1\nb=2\n")
  // set flushes for durability, so two sets leave two L0 tables.
  assert_true(run(db, ["stats"]).contains("l0: 2 tables"))
}

test "clicore binary keys and values render as hex" {
  let db = @regolith.Db::open_memory()
  db.put(
    Bytes::from_array([(0).to_byte(), (0xFF).to_byte()]),
    Bytes::from_array([(0xFE).to_byte()]),
  )
  assert_true(run(db, ["scan"]).contains("0x00ff=0xfe"))
}

test "clicore usage errors" {
  let db = @regolith.Db::open_memory()
  assert_true(run(db, []) == "error: no command (try \"help\")")
  assert_true(run(db, ["nope"]) == "error: unknown command nope (try \"help\")")
  assert_true(run(db, ["get"]) == "error: usage: get <key>")
  assert_true(run(db, ["set", "k"]) == "error: usage: set <key> <value>")
}

test "clicore flush and compact" {
  let ms = @regolith.MemoryStorage::new()
  let opts = @regolith.Options::default().with_compaction_trigger(2)
  let db = @regolith.Db::open_with_options(@regolith.Storage::Memory(ms), opts)
  let _ = run(db, ["set", "a", "1"])
  assert_true(run(db, ["flush"]) == "ok")
  let _ = run(db, ["set", "b", "2"])
  assert_true(run(db, ["flush"]) == "ok")
  assert_true(db.stats().l1_files == 1)
  assert_true(db.stats().l0_files == 0)
  assert_true(run(db, ["compact"]) == "ok")
  // Entries survive the manual compaction.
  assert_true(run(db, ["get", "a"]) == "1")
  assert_true(run(db, ["get", "b"]) == "2")
}
