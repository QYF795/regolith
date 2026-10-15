// storage_test.mbt

test "memory storage round trip" {
  let s = Storage::Memory(MemoryStorage::new())
  assert_true(read(s, "WAL") is None)
  write(s, "WAL", b"abc")
  assert_true(read(s, "WAL") == Some(b"abc"))
  write(s, "L0_000000.sst", b"xyz")
  let names = list(s, "L0_")
  assert_true(names.length() == 1)
  assert_true(names[0] == "L0_000000.sst")
  assert_true(exists(s, "WAL"))
  remove(s, "WAL")
  assert_true(read(s, "WAL") is None)
  assert_true(!exists(s, "WAL"))
}

test "file storage round trip" {
  let dir = "regolith-test-storage"
  let s = Storage::File(FileStorage::new(dir))
  ensure_ready(s)
  write(s, "WAL", b"abc")
  assert_true(read(s, "WAL") == Some(b"abc"))
  write(s, "L0_000001.sst", b"xyz")
  let names = list(s, "L0_")
  assert_true(names.length() == 1)
  remove(s, "WAL")
  remove(s, "L0_000001.sst")
  assert_true(list(s, "L0_").length() == 0)
  assert_true(read(s, "WAL") is None)
  @fs.remove_dir(dir) catch {
    _ => ()
  }
}

test "failpoint failread fires once" {
  let fp = FailpointStorage::new()
  write(Storage::Failpoint(fp), "WAL", b"abc")
  fp.arm(FaultKind::FailRead)
  let r = try {
    let _ = read(Storage::Failpoint(fp), "WAL")
    None
  } catch {
    e => Some(e)
  }
  match r {
    Some(DbError::Fault(_)) => ()
    _ => abort("expected injected Fault")
  }
  assert_true(!fp.armed())
  assert_true(read(Storage::Failpoint(fp), "WAL") == Some(b"abc"))
}

test "failpoint torn write leaves prefix" {
  let fp = FailpointStorage::new()
  fp.arm(FaultKind::TornWrite)
  let r = try {
    write(Storage::Failpoint(fp), "WAL", b"abcdef")
    None
  } catch {
    e => Some(e)
  }
  match r {
    Some(DbError::Fault(_)) => ()
    _ => abort("expected injected Fault")
  }
  assert_true(read(Storage::Failpoint(fp), "WAL") == Some(b"abc"))
}

test "failpoint lost write only hits WAL" {
  let fp = FailpointStorage::new()
  fp.arm(FaultKind::LostWrite)
  write(Storage::Failpoint(fp), "WAL", b"abc")
  assert_true(read(Storage::Failpoint(fp), "WAL") is None)
  // The fault is one-shot: the next WAL write lands.
  write(Storage::Failpoint(fp), "WAL", b"abc")
  assert_true(read(Storage::Failpoint(fp), "WAL") == Some(b"abc"))
  // A LostWrite fault ignores table writes entirely.
  fp.arm(FaultKind::LostWrite)
  write(Storage::Failpoint(fp), "L0_000000.sst", b"xyz")
  assert_true(fp.armed())
  assert_true(read(Storage::Failpoint(fp), "L0_000000.sst") == Some(b"xyz"))
}
