// wal_test.mbt

test "wal round trip" {
  let w = Wal::new()
  w.append(b"a", Some(b"1"), 1UL)
  w.append(b"b", None, 2UL)
  w.append(b"c", Some(b"333"), 3UL)
  let bytes = w.encode()
  let (records, valid) = parse_wal(bytes)
  assert_true(valid == bytes.length())
  assert_true(records.length() == 3)
  assert_true(records[0].key == b"a")
  assert_true(records[0].value == Some(b"1"))
  assert_true(records[0].seq == 1UL)
  assert_true(records[1].value is None)
  assert_true(records[2].key == b"c")
  assert_true(records[2].value == Some(b"333"))
}

test "wal truncated tail stops at prefix" {
  let w = Wal::new()
  w.append(b"a", Some(b"1"), 1UL)
  w.append(b"b", Some(b"2"), 2UL)
  let bytes = w.encode()
  let cut = bytes[0:bytes.length() - 3].to_owned()
  let (records, valid) = parse_wal(cut)
  assert_true(records.length() == 1)
  assert_true(records[0].key == b"a")
  assert_true(valid <= cut.length())
}

test "wal corrupted record stops parse" {
  let w = Wal::new()
  w.append(b"a", Some(b"1"), 1UL)
  w.append(b"b", Some(b"2"), 2UL)
  w.append(b"c", Some(b"3"), 3UL)
  let bytes = w.encode()
  let arr = bytes.to_array()
  let mid = bytes.length() / 2
  arr[mid] = (arr[mid].to_int() ^ 0xFF).to_byte()
  let (records, _valid) = parse_wal(Bytes::from_array(arr))
  assert_true(records.length() >= 1)
  assert_true(records[0].key == b"a")
}

test "wal batch record round trips as contiguous seqs" {
  let w = Wal::new()
  let ops : Array[(Bytes, Option[Bytes])] = [
    (b"a", Some(b"1")),
    (b"b", None),
    (b"c", Some(b"3")),
  ]
  w.append_batch(ops, 5UL)
  let (records, valid) = parse_wal(w.encode())
  assert_true(valid == w.encode().length())
  assert_true(records.length() == 3)
  assert_true(records[0].key == b"a" && records[0].seq == 5UL)
  assert_true(records[1].key == b"b" && records[1].seq == 6UL)
  assert_true(records[1].value is None)
  assert_true(records[2].key == b"c" && records[2].seq == 7UL)
}

test "wal torn batch record drops the whole batch" {
  let w = Wal::new()
  w.append(b"x", Some(b"1"), 1UL)
  let ops : Array[(Bytes, Option[Bytes])] = [(b"a", Some(b"1")), (b"b", Some(b"2"))]
  w.append_batch(ops, 2UL)
  let bytes = w.encode()
  // Cut inside the batch record: the valid prefix keeps only "x".
  let cut = bytes[0:bytes.length() - 2].to_owned()
  let (records, _valid) = parse_wal(cut)
  assert_true(records.length() == 1)
  assert_true(records[0].key == b"x")
}

test "wal put of empty value is not a tombstone" {
  let w = Wal::new()
  w.append(b"k", Some(b""), 1UL)
  w.append(b"t", None, 2UL)
  let (records, _valid) = parse_wal(w.encode())
  assert_true(records.length() == 2)
  assert_true(records[0].value == Some(b""))
  assert_true(records[1].value is None)
}
