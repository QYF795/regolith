// sstable_test.mbt

fn entry(key : Bytes, seq : UInt64, value : Option[Bytes]) -> Entry {
  { key, seq, value }
}

test "sstable round trip" {
  let b = SstBuilder::new(block_size=4096)
  b.add(entry(b"a", 1UL, Some(b"1")))
  b.add(entry(b"b", 2UL, None))
  b.add(entry(b"c", 3UL, Some(b"333")))
  let r = parse(b.finish())
  assert_true(r.get(b"a") == Some(Some(b"1")))
  assert_true(r.get(b"b") == Some(None))
  assert_true(r.get(b"c") == Some(Some(b"333")))
  assert_true(r.get(b"z") is None)
}

test "sstable multiple blocks" {
  let b = SstBuilder::new(block_size=64)
  for i = 0; i < 100; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    b.add(entry(k, i.to_uint64() + 1UL, Some(k)))
  }
  let r = parse(b.finish())
  for i = 0; i < 100; i = i + 1 {
    let k = Bytes::from_array([i.to_byte()])
    assert_true(r.get(k) == Some(Some(k)))
  }
  let miss = r.get(Bytes::from_array([(200).to_byte()]))
  assert_true(miss is None)
  let c = r.cursor()
  let mut n = 0
  while true {
    match c.peek() {
      None => break
      Some(_e) => {
        n = n + 1
        c.advance()
      }
    }
  }
  assert_true(n == 100)
  assert_true(c.error() is None)
}

fn expect_corrupt(bytes : Bytes) -> Unit {
  let r = try {
    let _ = parse(bytes)
    None
  } catch {
    e => Some(e)
  }
  match r {
    Some(DbError::Corrupt(_)) => ()
    _ => abort("expected Corrupt")
  }
}

test "sstable corruption detected" {
  let b = SstBuilder::new()
  b.add(entry(b"a", 1UL, Some(b"1")))
  let bytes = b.finish()
  // Truncated file.
  expect_corrupt(bytes[0:bytes.length() - 1].to_owned())
  // Flipped byte in the body (caught by the body checksum).
  let arr = bytes.to_array()
  arr[5] = (arr[5].to_int() ^ 1).to_byte()
  expect_corrupt(Bytes::from_array(arr))
  // Flipped byte in the magic.
  let arr2 = bytes.to_array()
  let last = arr2.length() - 1
  arr2[last] = (arr2[last].to_int() ^ 1).to_byte()
  expect_corrupt(Bytes::from_array(arr2))
}
