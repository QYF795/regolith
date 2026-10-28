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
  // Flipped byte in the bloom segment (also covered by the body checksum).
  let arr3 = bytes.to_array()
  let l3 = arr3.length()
  arr3[l3 - 31] = (arr3[l3 - 31].to_int() ^ 1).to_byte()
  expect_corrupt(Bytes::from_array(arr3))
  // Flipped byte in the magic.
  let arr2 = bytes.to_array()
  let last = arr2.length() - 1
  arr2[last] = (arr2[last].to_int() ^ 1).to_byte()
  expect_corrupt(Bytes::from_array(arr2))
}

test "sst cursor rejects duplicate keys as corrupt" {
  // Semantic corruption CRC cannot see: a table whose keys repeat. parse()
  // only checks the block index, so the file opens; the cursor must fail
  // instead of silently re-yielding the duplicate.
  let b = SstBuilder::new()
  b.add(entry(b"a", 1UL, Some(b"1")))
  b.add(entry(b"b", 2UL, Some(b"2")))
  b.add(entry(b"a", 3UL, Some(b"3")))
  let r = parse(b.finish())
  let c = r.cursor()
  assert_true(c.peek().map(fn(e) { e.seq }) == Some(1UL))
  c.advance()
  assert_true(c.peek().map(fn(e) { e.seq }) == Some(2UL))
  c.advance()
  // The third entry repeats key "a": no entry, and a Corrupt error.
  assert_true(c.peek() is None)
  assert_true(c.error() is Some(_))
  match c.error() {
    Some(DbError::Corrupt(_)) => ()
    _ => abort("expected Corrupt from a duplicate-key table")
  }
}

test "sst cursor rejects out-of-order keys as corrupt" {
  let b = SstBuilder::new()
  b.add(entry(b"b", 2UL, Some(b"2")))
  b.add(entry(b"a", 1UL, Some(b"1")))
  let r = parse(b.finish())
  let c = r.cursor()
  assert_true(c.peek().map(fn(e) { e.seq }) == Some(2UL))
  c.advance()
  assert_true(c.peek() is None)
  match c.error() {
    Some(DbError::Corrupt(_)) => ()
    _ => abort("expected Corrupt from an out-of-order table")
  }
}

test "sstable v2 bloom has no false negatives" {
  let b = SstBuilder::new(block_size=64)
  // Keys must ascend: [0,0],[0,1],...,[0,249],[1,0],...
  for i = 0; i < 500; i = i + 1 {
    let k = Bytes::from_array([(i / 250).to_byte(), (i % 250).to_byte()])
    b.add(entry(k, i.to_uint64() + 1UL, Some(b"v")))
  }
  let r = parse(b.finish())
  // Every inserted key must pass the filter and read back.
  for i = 0; i < 500; i = i + 1 {
    let k = Bytes::from_array([(i / 250).to_byte(), (i % 250).to_byte()])
    assert_true(r.may_contain(k))
    assert_true(r.get(k) == Some(Some(b"v")))
  }
  // Absent keys (250..254 in the first byte, disjoint from the inserts):
  // the filter may say yes (false positive) but the lookup must say no.
  let mut fp_count = 0
  for i = 0; i < 500; i = i + 1 {
    let k = Bytes::from_array([(250 + i % 5).to_byte(), (0).to_byte()])
    if r.may_contain(k) {
      fp_count = fp_count + 1
      assert_true(r.get(k) is None)
    }
  }
  // 10 bits/key with k=7 hashes gives ~0.8% false positives in expectation;
  // allow a very generous bound to keep the test stable across platforms.
  assert_true(fp_count < 100)
}

// --- hand-built v1 file (test-local encoders; all values < 128) ---

fn t_varint(buf : @buffer.Buffer, v : UInt64) -> Unit {
  buf.write_byte((v & 0x7FUL).to_int().to_byte())
}

fn t_u64_le(buf : @buffer.Buffer, v : UInt64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    buf.write_byte(((v >> (i * 8)) & 0xFFUL).to_int().to_byte())
  }
}

fn t_u32_le(buf : @buffer.Buffer, v : UInt) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    buf.write_byte(((v >> (i * 8)) & 0xFFU).reinterpret_as_int().to_byte())
  }
}

fn t_entry(buf : @buffer.Buffer, e : Entry) -> Unit {
  t_varint(buf, if e.value is None { 1UL } else { 0UL })
  t_varint(buf, e.seq)
  t_varint(buf, e.key.length().to_uint64())
  buf.write_bytes(e.key)
  match e.value {
    None => t_varint(buf, 0UL)
    Some(v) => {
      t_varint(buf, v.length().to_uint64())
      buf.write_bytes(v)
    }
  }
}

/// Builds an SSTable v1 file by hand (same layout as the pre-v2 builder) to
/// prove old files still parse and read correctly.
fn build_v1_table(entries : Array[Entry]) -> Bytes {
  let data = @buffer.Buffer(size_hint=64)
  let index = @buffer.Buffer(size_hint=32)
  t_varint(data, entries.length().to_uint64())
  for e in entries {
    t_entry(data, e)
  }
  let idx_off = data.length()
  t_varint(index, 1UL)
  let last = entries[entries.length() - 1]
  t_varint(index, last.key.length().to_uint64())
  index.write_bytes(last.key)
  t_varint(index, 0UL)
  data.write_bytes(index.to_bytes())
  let body = data.to_bytes()
  let footer = @buffer.Buffer(size_hint=24)
  t_u64_le(footer, idx_off.to_uint64())
  let crc = crc32(body)
  t_u32_le(footer, crc)
  let crc2 = crc32(footer.to_bytes())
  t_u32_le(footer, crc2)
  footer.write_bytes(b"RGSST1")
  body + footer.to_bytes()
}

test "sstable v1 files still parse (no bloom, may_contain always true)" {
  let bytes = build_v1_table(
    [entry(b"a", 1UL, Some(b"1")), entry(b"b", 2UL, None), entry(b"c", 3UL, Some(b"333"))],
  )
  let r = parse(bytes)
  assert_true(r.get(b"a") == Some(Some(b"1")))
  assert_true(r.get(b"b") == Some(None))
  assert_true(r.get(b"c") == Some(Some(b"333")))
  assert_true(r.get(b"z") is None)
  assert_true(r.may_contain(b"a"))
  assert_true(r.may_contain(b"definitely-absent"))
}
