// memtable_test.mbt

test "memtable put and get" {
  let mt = MemTable::new()
  mt.put(b"a", Some(b"1"), 1UL)
  mt.put(b"b", Some(b"2"), 2UL)
  assert_true(mt.get(b"a") == Some(Some(b"1")))
  assert_true(mt.get(b"b") == Some(Some(b"2")))
  assert_true(mt.get(b"c") is None)
}

test "memtable overwrite and tombstone" {
  let mt = MemTable::new()
  mt.put(b"k", Some(b"v1"), 1UL)
  mt.put(b"k", Some(b"v2"), 2UL)
  assert_true(mt.get(b"k") == Some(Some(b"v2")))
  mt.put(b"k", None, 3UL)
  assert_true(mt.get(b"k") == Some(None))
  assert_true(mt.max_seq() == 3UL)
}

test "memtable ordered iteration" {
  let mt = MemTable::new()
  mt.put(b"c", Some(b"3"), 3UL)
  mt.put(b"a", Some(b"1"), 1UL)
  mt.put(b"b", Some(b"2"), 2UL)
  let keys : Array[Bytes] = []
  let it = mt.iter()
  while true {
    match it.peek() {
      None => break
      Some(e) => {
        keys.push(e.key)
        it.advance()
      }
    }
  }
  assert_true(keys.length() == 3)
  assert_true(keys[0] == b"a")
  assert_true(keys[1] == b"b")
  assert_true(keys[2] == b"c")
}

test "memtable delete then put stays a single node" {
  let mt = MemTable::new()
  mt.put(b"k", Some(b"v1"), 1UL)
  mt.put(b"k", None, 2UL)
  mt.put(b"k", Some(b"v2"), 3UL)
  assert_true(mt.get(b"k") == Some(Some(b"v2")))
  assert_true(mt.size_bytes() == 27) // key 1 + value 2 + 24: exactly one node
  let it = mt.iter()
  let n = Ref(0)
  while true {
    match it.peek() {
      None => break
      Some(_) => {
        n.val = n.val + 1
        it.advance()
      }
    }
  }
  assert_true(n.val == 1)
}

// Regression: overwrites and tombstones interleaved across keys must leave
// exactly one node per key. An overwrite that linked a duplicate node at the
// upper levels and then returned used to leave an orphan whose level-0
// pointer was None; a later put walking through it would link its new node
// into the void and the entry would vanish from lookups and iteration.
test "memtable overwrite keeps size and iteration consistent" {
  let mt = MemTable::new()
  mt.put(b"a", Some(b"1"), 1UL)
  mt.put(b"b", Some(b"2"), 2UL)
  mt.put(b"a", None, 3UL)
  mt.put(b"c", Some(b"3"), 4UL)
  mt.put(b"b", Some(b"22"), 5UL)
  mt.put(b"a", Some(b"11"), 6UL)
  mt.put(b"c", None, 7UL)
  assert_true(mt.get(b"a") == Some(Some(b"11")))
  assert_true(mt.get(b"b") == Some(Some(b"22")))
  assert_true(mt.get(b"c") == Some(None))
  assert_true(mt.size_bytes() == 27 + 27 + 25)
  let it = mt.iter()
  let n = Ref(0)
  while true {
    match it.peek() {
      None => break
      Some(_) => {
        n.val = n.val + 1
        it.advance()
      }
    }
  }
  assert_true(n.val == 3)
}

test "memtable many keys" {
  let mt = MemTable::new()
  for i = 0; i < 500; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    mt.put(k, Some(b"v"), i.to_uint64() + 1UL)
  }
  for i = 0; i < 500; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    assert_true(mt.get(k) == Some(Some(b"v")))
  }
  assert_true(!mt.is_empty())
  assert_true(mt.size_bytes() > 0)
  assert_true(mt.max_seq() == 500UL)
}
