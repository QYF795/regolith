// order_test.mbt
//
// Key order is lexicographic byte order everywhere: the skip list, the merge
// iterator and the SSTable index must all agree. These tests use keys of
// mixed lengths, where length-first comparison (Bytes::compare) disagrees
// with bytewise order — a regression guard for the ordering fix.

fn keys_of(db : Db) -> Array[Bytes] {
  let keys : Array[Bytes] = []
  let it = db.scan()
  while true {
    match it.next() {
      None => break
      Some(e) => keys.push(e.key)
    }
  }
  keys
}

test "memtable orders keys lexicographically not by length" {
  let db = Db::open_memory()
  db.put(b"b", b"2")
  db.put(b"aa", b"1")
  db.put(b"a", b"3")
  db.put(b"bbb", b"4")
  let keys = keys_of(db)
  assert_eq(keys.length(), 4)
  assert_eq(keys[0], b"a")
  assert_eq(keys[1], b"aa")
  assert_eq(keys[2], b"b")
  assert_eq(keys[3], b"bbb")
}

test "sst index and get agree on lexicographic order across blocks" {
  let ms = MemoryStorage::new()
  let opts = { ..Options::default(), block_size: 20 }
  let db1 = Db::open_with_options(Storage::Memory(ms), opts)
  // Inserted out of order on purpose; the store must sort them bytewise.
  db1.put(b"k", b"1")
  db1.put(b"aa", b"2")
  db1.put(b"longer", b"3")
  db1.put(b"bb", b"4")
  db1.put(b"x", b"5")
  db1.flush()
  // Reopen: everything below goes through the persisted index and bloom.
  let db2 = Db::open_with_options(Storage::Memory(ms), opts)
  let keys = keys_of(db2)
  assert_eq(keys.length(), 5)
  assert_eq(keys[0], b"aa")
  assert_eq(keys[1], b"bb")
  assert_eq(keys[2], b"k")
  assert_eq(keys[3], b"longer")
  assert_eq(keys[4], b"x")
  // Point reads must find the right value for every key.
  assert_eq(db2.get(b"aa"), Some(Some(b"2")))
  assert_eq(db2.get(b"bb"), Some(Some(b"4")))
  assert_eq(db2.get(b"k"), Some(Some(b"1")))
  assert_eq(db2.get(b"longer"), Some(Some(b"3")))
  assert_eq(db2.get(b"x"), Some(Some(b"5")))
  assert_eq(db2.get(b"nope"), None)
}
