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
