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

// --- hand-built v2/v3 files (test-local encoders; all values < 128) ---

/// Builds an SSTable v2 file by hand (pre-v3 layout: block count + full-key
/// entries, no restarts, empty bloom) to prove files written by 0.4.x still
/// parse and read correctly next to v3 tables.
pub fn build_v2_table(entries : Array[Entry]) -> Bytes {
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
  // Empty bloom (n=0, m_bits=0): legal in v2; the filter simply never fires.
  let bloom_off = data.length()
  t_varint(data, 0UL)
  t_varint(data, 0UL)
  let body = data.to_bytes()
  let footer = @buffer.Buffer(size_hint=32)
  t_u64_le(footer, idx_off.to_uint64())
  t_u64_le(footer, bloom_off.to_uint64())
  let crc = crc32(body)
  t_u32_le(footer, crc)
  let crc2 = crc32(footer.to_bytes())
  t_u32_le(footer, crc2)
  footer.write_bytes(b"RGSST2")
  body + footer.to_bytes()
}

/// Like build_v2_table but with an unknown magic and a valid v2-style crc2:
/// what a table from a newer regolith version looks like to this one.
pub fn build_future_table(entries : Array[Entry]) -> Bytes {
  let bytes = build_v2_table(entries)
  let arr = bytes.to_array()
  for i = 0; i < 6; i = i + 1 {
    arr[arr.length() - 6 + i] = b"RGSST9"[i]
  }
  Bytes::from_array(arr)
}

/// Builds an SSTable v3 file by hand (prefix-compressed block + restart
/// array), mirroring the real encoder so corruption tests can flip exact
/// bytes. Single block, empty bloom.
fn build_v3_table(entries : Array[Entry], restart_interval : Int) -> Bytes {
  let block = @buffer.Buffer(size_hint=64)
  let restarts : Array[Int] = []
  let mut prev : Option[Bytes] = None
  let mut idx = 0
  for e in entries {
    if idx % restart_interval == 0 {
      restarts.push(block.length())
      prev = None
    }
    let kl = e.key.length()
    let shared = match prev {
      None => 0
      Some(p) => {
        let n = if p.length() < kl { p.length() } else { kl }
        let mut s = 0
        while s < n && p[s] == e.key[s] {
          s = s + 1
        }
        s
      }
    }
    t_varint(block, shared.to_uint64())
    t_varint(block, (kl - shared).to_uint64())
    t_varint(block, if e.value is None { 1UL } else { 0UL })
    t_varint(block, e.seq)
    let vl = match e.value {
      None => 0
      Some(v) => v.length()
    }
    t_varint(block, vl.to_uint64())
    block.write_bytes(e.key[shared:kl])
    match e.value {
      None => ()
      Some(v) => block.write_bytes(v)
    }
    prev = Some(e.key)
    idx = idx + 1
  }
  for off in restarts {
    t_u32_le(block, off.reinterpret_as_uint())
  }
  t_u32_le(block, restarts.length().reinterpret_as_uint())
  let data = @buffer.Buffer(size_hint=64)
  data.write_bytes(block.to_bytes())
  let idx_off = data.length()
  let index = @buffer.Buffer(size_hint=32)
  t_varint(index, 1UL)
  let last = entries[entries.length() - 1]
  t_varint(index, last.key.length().to_uint64())
  index.write_bytes(last.key)
  t_varint(index, 0UL)
  data.write_bytes(index.to_bytes())
  let bloom_off = data.length()
  t_varint(data, 0UL)
  t_varint(data, 0UL)
  let body = data.to_bytes()
  let footer = @buffer.Buffer(size_hint=32)
  t_u64_le(footer, idx_off.to_uint64())
  t_u64_le(footer, bloom_off.to_uint64())
  let crc = crc32(body)
  t_u32_le(footer, crc)
  // v3 crc2 covers the footer except the crc2 field itself.
  footer.write_bytes(b"RGSST3")
  let crc2 = crc32(footer.to_bytes())
  let final_footer = @buffer.Buffer(size_hint=32)
  final_footer.write_bytes(footer.to_bytes()[0:20])
  t_u32_le(final_footer, crc2)
  final_footer.write_bytes(footer.to_bytes()[20:26])
  body + final_footer.to_bytes()
}

/// Flips byte `at` to `val` in a v3 table and repairs the body checksum,
/// so the corruption survives the CRC gate and the v3 restart validation
/// itself must reject the file. The footer (and its crc2) is untouched.
fn set_v3_byte(bytes : Bytes, at : Int, val : Int) -> Bytes {
  let arr = bytes.to_array()
  arr[at] = val.to_byte()
  let fb = arr.length() - 30
  let crc = crc32(Bytes::from_array(arr)[0:fb].to_owned())
  for i = 0; i < 4; i = i + 1 {
    arr[fb + 16 + i] = ((crc >> (i * 8)) & 0xFFU).reinterpret_as_int().to_byte()
  }
  Bytes::from_array(arr)
}

/// Reads idx_off from the footer of a hand-built single-block v3 table:
/// with an empty bloom, the block's restart section ends exactly there, so
/// num_r sits at idx_off - 4 and restart offsets just before it.
fn v3_block_end(bytes : Bytes) -> Int {
  let fb = bytes.length() - 30
  let mut v = 0
  for i = 0; i < 8; i = i + 1 {
    v = v | (bytes[fb + i].to_int() << (i * 8))
  }
  v
}

/// Expects a Corrupt raise either while parsing the table or while looking
/// up `key` in it.
fn expect_corrupt_get(bytes : Bytes, key : Bytes) -> Unit {
  let res = try {
    let _ = parse(bytes).get(key)
    None
  } catch {
    e => Some(e)
  }
  match res {
    Some(DbError::Corrupt(_)) => ()
    _ => abort("expected Corrupt")
  }
}

/// Reference point lookup: a full sequential cursor scan, the path get()
/// replaces with the restart binary search on v3 blocks.
fn linear_lookup(r : SstReader, key : Bytes) -> Option[Option[Bytes]] {
  let c = r.cursor()
  while true {
    match c.peek() {
      None => {
        if c.error() is Some(_) {
          abort("cursor failed in reference scan")
        }
        return None
      }
      Some(e) => {
        let cmp = e.key.lexical_compare(key)
        if cmp == 0 {
          return Some(e.value)
        }
        if cmp > 0 {
          return None
        }
        c.advance()
      }
    }
  }
  None
}

fn z_key(n : Int) -> Bytes {
  let arr : Array[Byte] = []
  for _i = 0; _i < n; _i = _i + 1 {
    arr.push((122).to_byte())
  }
  Bytes::from_array(arr)
}

// --- v3 prefix compression ---

test "v3 prefix compression round trip" {
  // Long shared prefixes, a tombstone, an empty (live) value, a zero-share
  // transition, and a very long key. Restart points at entries 0 and 4.
  let b = SstBuilder::new(block_size=4096, restart_interval=4)
  let keys = [
    b"user:1000:session:alice",
    b"user:1000:session:bob",
    b"user:1000:session:carol",
    b"user:1000:session:dave",
    b"user:2000:session:alice",
    z_key(200),
  ]
  b.add(entry(keys[0], 1UL, Some(b"v0")))
  b.add(entry(keys[1], 2UL, None))
  b.add(entry(keys[2], 3UL, Some(b"")))
  b.add(entry(keys[3], 4UL, Some(b"v3")))
  b.add(entry(keys[4], 5UL, None))
  b.add(entry(keys[5], 6UL, Some(b"long")))
  let r = parse(b.finish())
  assert_true(r.first_key() == keys[0])
  assert_true(r.get(keys[0]) == Some(Some(b"v0")))
  assert_true(r.get(keys[1]) == Some(None))
  assert_true(r.get(keys[2]) == Some(Some(b"")))
  assert_true(r.get(keys[3]) == Some(Some(b"v3")))
  assert_true(r.get(keys[4]) == Some(None))
  assert_true(r.get(keys[5]) == Some(Some(b"long")))
  // Absent keys: between restart keys, before the first key, past the last.
  assert_true(r.get(b"user:1500:session:x") is None)
  assert_true(r.get(b"aaa") is None)
  assert_true(r.get(z_key(201)) is None)
  // The cursor yields all six keys in order.
  let c = r.cursor()
  let mut i = 0
  while true {
    match c.peek() {
      None => break
      Some(e) => {
        assert_true(e.key == keys[i])
        i = i + 1
        c.advance()
      }
    }
  }
  assert_true(i == 6)
  assert_true(c.error() is None)
}

test "v3 prefix compression across block and restart boundaries" {
  // 4-byte keys sharing 3 bytes within each 256-run; blocks hold 5 entries
  // and restart points sit at positions 0 and 3, so block boundaries land
  // mid-interval and every block starts with a full-key restart entry.
  let b = SstBuilder::new(block_size=48, restart_interval=3)
  for i = 0; i < 300; i = i + 1 {
    let k = Bytes::from_array([(i >> 8).to_byte(), (i & 255).to_byte(), (7).to_byte(), (7).to_byte()])
    b.add(entry(k, i.to_uint64() + 1UL, Some(k)))
  }
  let r = parse(b.finish())
  for i = 0; i < 300; i = i + 1 {
    let k = Bytes::from_array([(i >> 8).to_byte(), (i & 255).to_byte(), (7).to_byte(), (7).to_byte()])
    assert_true(r.get(k) == Some(Some(k)))
  }
  // Absent keys sorting inside the range.
  assert_true(r.get(Bytes::from_array([(0).to_byte(), (128).to_byte(), (7).to_byte(), (6).to_byte()])) is None)
  assert_true(r.get(Bytes::from_array([(0).to_byte(), (0).to_byte(), (6).to_byte()])) is None)
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
  assert_true(n == 300)
  assert_true(c.error() is None)
}

test "v3 restart binary search matches full linear scan" {
  // Deterministic pseudo-random keys (LCG): the first two bytes strictly
  // increase, so keys ascend; random-length tails give varied shared
  // prefixes. Every key and several absent probes must agree between get()
  // (restart binary search) and a full cursor scan.
  let b = SstBuilder::new(block_size=256, restart_interval=8)
  let state = Ref(123456789L)
  let keys : Array[Bytes] = []
  for i = 0; i < 500; i = i + 1 {
    let tlen = state.val.to_int() % 9
    state.val = (state.val * 1103515245L + 12345L) & 0x7FFFFFFFL
    let arr : Array[Byte] = [(i >> 8).to_byte(), (i & 255).to_byte()]
    for _j = 0; _j < tlen; _j = _j + 1 {
      let x = (state.val & 0x7FL).to_int()
      state.val = (state.val * 1103515245L + 12345L) & 0x7FFFFFFFL
      arr.push(x.to_byte())
    }
    let k = Bytes::from_array(arr)
    b.add(entry(k, i.to_uint64() + 1UL, Some(k)))
    keys.push(k)
  }
  let r = parse(b.finish())
  for i = 0; i < 500; i = i + 1 {
    let k = keys[i]
    let want = linear_lookup(r, k)
    assert_true(r.get(k) == want)
    // Probes around the key: the bare 2-byte prefix (which equals the key
    // itself when the tail is empty) and a 0xFF tail (tails are masked to
    // 0x7F, so this always sorts strictly after the key).
    let bare = Bytes::from_array([(i >> 8).to_byte(), (i & 255).to_byte()])
    assert_true(r.get(bare) == linear_lookup(r, bare))
    let hi_arr : Array[Byte] = [(i >> 8).to_byte(), (i & 255).to_byte()]
    for _j = 0; _j < 12; _j = _j + 1 {
      hi_arr.push((255).to_byte())
    }
    let hi = Bytes::from_array(hi_arr)
    assert_true(r.get(hi) == linear_lookup(r, hi))
  }
}

test "v2 and v3 tables coexist (upgrade path)" {
  let r2 = parse(build_v2_table(
    [entry(b"old:1", 1UL, Some(b"x")), entry(b"old:2", 2UL, None)],
  ))
  assert_true(r2.get(b"old:1") == Some(Some(b"x")))
  assert_true(r2.get(b"old:2") == Some(None))
  // The hand-built v2 table has an empty bloom: with no filter the reader
  // conservatively answers "present", and the real lookup still returns a
  // clean miss for absent keys.
  assert_true(r2.may_contain(b"old:1"))
  assert_true(r2.get(b"absent") is None)
  let b = SstBuilder::new()
  b.add(entry(b"new:1", 3UL, Some(b"y")))
  b.add(entry(b"new:2", 4UL, Some(b"z")))
  let r3 = parse(b.finish())
  assert_true(r3.get(b"new:1") == Some(Some(b"y")))
  assert_true(r3.get(b"new:2") == Some(Some(b"z")))
}

test "v2 table with an empty first key still parses" {
  // Regression: first_key on v2 used to reject kl == 0, which made tables
  // whose first entry is the empty key unreadable.
  let r = parse(build_v2_table(
    [entry(b"", 1UL, Some(b"empty")), entry(b"a", 2UL, Some(b"1"))],
  ))
  assert_true(r.first_key() == b"")
  assert_true(r.get(b"") == Some(Some(b"empty")))
  assert_true(r.get(b"a") == Some(Some(b"1")))
}

test "v3 block corruption is detected" {
  // (a) shared > previous key length: entry 1 of a 3-entry block claims a
  // 127-byte prefix over a 2-byte previous key.
  let t1 = build_v3_table(
    [
      entry(b"aa", 1UL, Some(b"v")),
      entry(b"ab", 2UL, Some(b"v")),
      entry(b"ac", 3UL, Some(b"v")),
    ],
    16,
  )
  // entry 0 = shared,unshared,tomb,seq,vl + 2 key bytes + 1 value byte = 8
  // bytes; entry 1's shared varint is byte 8.
  expect_corrupt_get(set_v3_byte(t1, 8, 127), b"ab")
  expect_corrupt_get(set_v3_byte(t1, 8, 127), b"aa")
  // (b) a restart entry whose shared is nonzero: the first entry of the
  // block must store the full key.
  let t2 = build_v3_table([entry(b"aa", 1UL, Some(b"v")), entry(b"ab", 2UL, Some(b"v"))], 16)
  expect_corrupt_get(set_v3_byte(t2, 0, 1), b"aa")
  // (c) num_r == 0: the restart array must have at least one entry. The
  // hand-built table has a single block and an empty bloom, so the block's
  // restart section ends at idx_off and num_r is the block's last byte.
  let t3 = build_v3_table([entry(b"aa", 1UL, Some(b"v"))], 16)
  expect_corrupt_get(set_v3_byte(t3, v3_block_end(t3) - 4, 0), b"aa")
  // (d) restart offsets not strictly increasing: with every entry a restart
  // point (interval 1), entry offsets are 0, 8, 16; flatten the middle one.
  // The second offset is the middle slot of the three just before num_r.
  let t4 = build_v3_table(
    [
      entry(b"aa", 1UL, Some(b"v")),
      entry(b"ab", 2UL, Some(b"v")),
      entry(b"ac", 3UL, Some(b"v")),
    ],
    1,
  )
  expect_corrupt_get(set_v3_byte(t4, v3_block_end(t4) - 12, 0), b"aa")
  // (e) num_r claiming more restart slots than the block holds.
  let t5 = build_v3_table([entry(b"aa", 1UL, Some(b"v"))], 16)
  expect_corrupt_get(set_v3_byte(t5, v3_block_end(t5) - 4, 127), b"aa")
}
