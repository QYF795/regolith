// sstable.mbt
//
// SSTable v2: the on-disk sorted table (v1 files are still readable). Layout
// (see docs/format.md §3):
//
//   blocks* index bloom footer
//   block  := count(varint) entry*
//   entry  := tomb(varint) seq(varint) kl(varint) key vl(varint) value
//   index  := m(varint) (kl(varint) last_key offset(varint))*
//   bloom  := n(varint) m_bits(varint) bits
//   footer := idx_off(u64 LE) bloom_off(u64 LE) crc(u32 LE) crc2(u32 LE)
//             magic("RGSST2")
//
// The bloom filter (k=7 double hashing, 10 bits per key) lets point reads
// skip tables that provably do not contain the key. crc covers everything
// before the footer; crc2 covers the footer's offset and checksum fields, so
// a single flipped byte anywhere in the file makes the whole table unreadable
// — reads can never return silently wrong data.

const SST_MAGIC_V1 : String = "RGSST1"
const SST_MAGIC_V2 : String = "RGSST2"
const FOOTER_V1 : Int = 22
const FOOTER_V2 : Int = 30
const BLOOM_SEED : UInt = 0xBC9F1D34U
const BLOOM_K : Int = 7
const BLOOM_BITS_PER_KEY : Int = 10

/// True when `bytes[at:at+magic.length()]` spells `magic` (ASCII).
fn magic_is(bytes : Bytes, at : Int, magic : String) -> Bool {
  if at < 0 || at + magic.length() > bytes.length() {
    return false
  }
  for j = 0; j < magic.length(); j = j + 1 {
    if bytes[at + j].to_int() != magic[j].to_int() {
      return false
    }
  }
  true
}

/// A key filter over the table. Built with LevelDB-style double hashing:
///
///   h  = crc32_init(key, BLOOM_SEED)
///   gi = (h + i * delta) % m,  delta = (h >> 17) | (h << 15)
///
/// k=7 probes into m=10·n bits gives ~0.8% false positives. A bloom "no" is
/// authoritative — the key is definitely absent; a bloom "yes" only decides
/// that the real lookup is worth doing.
pub(all) struct Bloom {
  m_bits : Int
  bits : Bytes
}

pub fn Bloom::may_contain(self : Bloom, key : Bytes) -> Bool {
  let m = self.m_bits
  if m == 0 {
    return false
  }
  let mut h = crc32_init(key, BLOOM_SEED)
  let delta = (h >> 17) | (h << 15)
  for _i = 0; _i < BLOOM_K; _i = _i + 1 {
    let bit = (h % m.reinterpret_as_uint()).reinterpret_as_int()
    if (self.bits[bit >> 3].to_int() & (1 << (bit & 7))) == 0 {
      return false
    }
    h = (h + delta) & 0xFFFFFFFFU
  }
  true
}

fn write_u64_le(buf : @buffer.Buffer, v : UInt64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    buf.write_byte(((v >> (i * 8)) & 0xFFUL).to_int().to_byte())
  }
}

fn write_u32_le(buf : @buffer.Buffer, v : UInt) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    buf.write_byte(((v >> (i * 8)) & 0xFFU).reinterpret_as_int().to_byte())
  }
}

fn read_u64_le(bytes : Bytes, at : Int) -> UInt64 {
  let mut v = 0UL
  for i = 0; i < 8; i = i + 1 {
    let part = bytes[at + i].to_int().reinterpret_as_uint().to_uint64() << (i * 8)
    v = v | part
  }
  v
}

fn read_u32_le(bytes : Bytes, at : Int) -> UInt {
  let mut v = 0U
  for i = 0; i < 4; i = i + 1 {
    let part = bytes[at + i].to_int().reinterpret_as_uint() << (i * 8)
    v = v | part
  }
  v
}

fn try_varint(bytes : Bytes, pos : Ref[Int]) -> Option[UInt64] {
  try {
    Some(read_varint(bytes, pos))
  } catch {
    _ => None
  }
}

fn encode_entry(buf : @buffer.Buffer, entry : Entry) -> Unit {
  put_varint(buf, if entry.value is None { 1UL } else { 0UL })
  put_varint(buf, entry.seq)
  put_varint(buf, entry.key.length().to_uint64())
  buf.write_bytes(entry.key)
  match entry.value {
    None => put_varint(buf, 0UL)
    Some(v) => {
      put_varint(buf, v.length().to_uint64())
      buf.write_bytes(v)
    }
  }
}

/// Builds an SSTable v2 from entries added in ascending key order.
pub(all) struct SstBuilder {
  data : @buffer.Buffer
  block : @buffer.Buffer
  index : @buffer.Buffer
  block_count : Ref[Int]
  index_count : Ref[Int]
  last_key : Ref[Option[Bytes]]
  bloom_hashes : Array[UInt]
  block_size : Int
}

pub fn SstBuilder::new(block_size~ : Int = 4096) -> SstBuilder {
  {
    data: @buffer.Buffer(size_hint=8192),
    block: @buffer.Buffer(size_hint=block_size),
    index: @buffer.Buffer(size_hint=256),
    block_count: Ref(0),
    index_count: Ref(0),
    last_key: Ref(None),
    bloom_hashes: [],
    block_size,
  }
}

fn SstBuilder::seal_block(self : SstBuilder) -> Unit {
  if self.block_count.val == 0 {
    return
  }
  match self.last_key.val {
    None => return
    Some(lk) => {
      put_varint(self.index, lk.length().to_uint64())
      self.index.write_bytes(lk)
    }
  }
  put_varint(self.index, self.data.length().to_uint64())
  put_varint(self.data, self.block_count.val.to_uint64())
  self.data.write_bytes(self.block.to_bytes())
  self.index_count.val = self.index_count.val + 1
  self.block.reset()
  self.block_count.val = 0
  self.last_key.val = None
}

/// Adds one entry. Keys must be strictly ascending.
pub fn SstBuilder::add(self : SstBuilder, entry : Entry) -> Unit {
  encode_entry(self.block, entry)
  self.block_count.val = self.block_count.val + 1
  self.last_key.val = Some(entry.key)
  self.bloom_hashes.push(crc32_init(entry.key, BLOOM_SEED))
  if self.block.length() >= self.block_size {
    self.seal_block()
  }
}

/// Finishes the table and returns the serialized bytes (v2, with bloom).
pub fn SstBuilder::finish(self : SstBuilder) -> Bytes {
  self.seal_block()
  let idx_off = self.data.length()
  // The index is written after the blocks, prefixed with the block count.
  let final_index = @buffer.Buffer(size_hint=self.index.length() + 8)
  put_varint(final_index, self.index_count.val.to_uint64())
  final_index.write_bytes(self.index.to_bytes())
  self.data.write_bytes(final_index.to_bytes())
  // The bloom segment: n(varint) m_bits(varint) bits. The bit size depends on
  // the final key count, so `add` records the raw hash and the filter is
  // materialized here.
  let bloom_off = self.data.length()
  let n = self.bloom_hashes.length()
  let m_bits = n * BLOOM_BITS_PER_KEY
  if m_bits > 0 {
    let nbytes = (m_bits + 7) / 8
    let bits : Array[Byte] = []
    for _i = 0; _i < nbytes; _i = _i + 1 {
      bits.push((0).to_byte())
    }
    for h0 in self.bloom_hashes {
      let mut h = h0
      let delta = (h >> 17) | (h << 15)
      for _i = 0; _i < BLOOM_K; _i = _i + 1 {
        let bit = (h % m_bits.reinterpret_as_uint()).reinterpret_as_int()
        bits[bit >> 3] = (bits[bit >> 3].to_int() | (1 << (bit & 7))).to_byte()
        h = (h + delta) & 0xFFFFFFFFU
      }
    }
    put_varint(self.data, n.to_uint64())
    put_varint(self.data, m_bits.to_uint64())
    self.data.write_bytes(Bytes::from_array(bits))
  } else {
    put_varint(self.data, 0UL)
    put_varint(self.data, 0UL)
  }
  let body = self.data.to_bytes()
  let footer = @buffer.Buffer(size_hint=32)
  write_u64_le(footer, idx_off.to_uint64())
  write_u64_le(footer, bloom_off.to_uint64())
  let crc = crc32(body)
  write_u32_le(footer, crc)
  let crc2 = crc32(footer.to_bytes())
  write_u32_le(footer, crc2)
  footer.write_bytes(b"RGSST2")
  body + footer.to_bytes()
}

/// A validated, read-only view of an SSTable file.
pub(all) struct SstReader {
  bytes : Bytes
  idx_off : Int
  index_keys : Array[Bytes]
  index_offsets : Array[Int]
  bloom : Option[Bloom]
}

/// Validates magic, both checksums and the index, then returns the reader.
/// v1 files (no bloom) are still accepted; they answer `may_contain` with
/// `true` and behave exactly as before.
pub fn parse(bytes : Bytes) -> SstReader raise DbError {
  if bytes.length() < FOOTER_V1 {
    raise DbError::Corrupt("sst: file too short")
  }
  if magic_is(bytes, bytes.length() - 6, SST_MAGIC_V1) {
    parse_v1(bytes)
  } else if magic_is(bytes, bytes.length() - 6, SST_MAGIC_V2) {
    parse_v2(bytes)
  } else {
    raise DbError::Corrupt("sst: bad magic")
  }
}

fn parse_v1(bytes : Bytes) -> SstReader raise DbError {
  let len = bytes.length()
  let fb = len - FOOTER_V1
  let crc = read_u32_le(bytes, fb + 8)
  let crc2 = read_u32_le(bytes, fb + 12)
  if crc32(bytes[0:fb]) != crc {
    raise DbError::Corrupt("sst: checksum mismatch")
  }
  if crc32(bytes[fb:fb + 12]) != crc2 {
    raise DbError::Corrupt("sst: footer checksum mismatch")
  }
  let idx_off = read_u64_le(bytes, fb).to_int()
  if idx_off < 0 || idx_off > fb {
    raise DbError::Corrupt("sst: index offset out of range")
  }
  let pos = Ref(idx_off)
  let m = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: bad index")
    Some(v) => v.to_int()
  }
  if m < 1 || m > 1_000_000 {
    raise DbError::Corrupt("sst: bad index size")
  }
  let keys : Array[Bytes] = []
  let offs : Array[Int] = []
  let mut prev_key = b""
  let mut prev_off = -1
  for _i = 0; _i < m; _i = _i + 1 {
    let kl = match try_varint(bytes, pos) {
      None => raise DbError::Corrupt("sst: bad index key")
      Some(v) => v.to_int()
    }
    if kl <= 0 || pos.val + kl > fb {
      raise DbError::Corrupt("sst: index key out of range")
    }
    let key = bytes[pos.val:pos.val + kl].to_owned()
    pos.val = pos.val + kl
    let off = match try_varint(bytes, pos) {
      None => raise DbError::Corrupt("sst: bad index offset")
      Some(v) => v.to_int()
    }
    if off < 0 || off >= idx_off {
      raise DbError::Corrupt("sst: block offset out of range")
    }
    if prev_off >= off {
      raise DbError::Corrupt("sst: block offsets not increasing")
    }
    if prev_off >= 0 && prev_key.lexical_compare(key) >= 0 {
      raise DbError::Corrupt("sst: index keys not increasing")
    }
    keys.push(key)
    offs.push(off)
    prev_key = key
    prev_off = off
  }
  if pos.val != fb {
    raise DbError::Corrupt("sst: trailing bytes in index")
  }
  {
    bytes: bytes,
    idx_off: idx_off,
    index_keys: keys,
    index_offsets: offs,
    bloom: None,
  }
}

fn parse_v2(bytes : Bytes) -> SstReader raise DbError {
  let len = bytes.length()
  if len < FOOTER_V2 + 1 {
    raise DbError::Corrupt("sst: file too short")
  }
  let fb = len - FOOTER_V2
  let crc = read_u32_le(bytes, fb + 16)
  let crc2 = read_u32_le(bytes, fb + 20)
  if crc32(bytes[0:fb]) != crc {
    raise DbError::Corrupt("sst: checksum mismatch")
  }
  if crc32(bytes[fb:fb + 20]) != crc2 {
    raise DbError::Corrupt("sst: footer checksum mismatch")
  }
  let idx_off = read_u64_le(bytes, fb).to_int()
  let bloom_off = read_u64_le(bytes, fb + 8).to_int()
  if idx_off < 0 || bloom_off < idx_off || bloom_off > fb {
    raise DbError::Corrupt("sst: offsets out of range")
  }
  let pos = Ref(idx_off)
  let m = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: bad index")
    Some(v) => v.to_int()
  }
  if m < 1 || m > 1_000_000 {
    raise DbError::Corrupt("sst: bad index size")
  }
  let keys : Array[Bytes] = []
  let offs : Array[Int] = []
  let mut prev_key = b""
  let mut prev_off = -1
  for _i = 0; _i < m; _i = _i + 1 {
    let kl = match try_varint(bytes, pos) {
      None => raise DbError::Corrupt("sst: bad index key")
      Some(v) => v.to_int()
    }
    if kl <= 0 || pos.val + kl > bloom_off {
      raise DbError::Corrupt("sst: index key out of range")
    }
    let key = bytes[pos.val:pos.val + kl].to_owned()
    pos.val = pos.val + kl
    let off = match try_varint(bytes, pos) {
      None => raise DbError::Corrupt("sst: bad index offset")
      Some(v) => v.to_int()
    }
    if off < 0 || off >= idx_off {
      raise DbError::Corrupt("sst: block offset out of range")
    }
    if prev_off >= off {
      raise DbError::Corrupt("sst: block offsets not increasing")
    }
    if prev_off >= 0 && prev_key.lexical_compare(key) >= 0 {
      raise DbError::Corrupt("sst: index keys not increasing")
    }
    keys.push(key)
    offs.push(off)
    prev_key = key
    prev_off = off
  }
  if pos.val != bloom_off {
    raise DbError::Corrupt("sst: trailing bytes in index")
  }
  // Bloom segment: n, m_bits, ceil(m_bits/8) bytes of bits.
  let bpos = Ref(bloom_off)
  let n = match try_varint(bytes, bpos) {
    None => raise DbError::Corrupt("sst: bad bloom header")
    Some(v) => v.to_int()
  }
  if n < 0 || n > 1_000_000 {
    raise DbError::Corrupt("sst: bad bloom count")
  }
  let m_bits = match try_varint(bytes, bpos) {
    None => raise DbError::Corrupt("sst: bad bloom bits")
    Some(v) => v.to_int()
  }
  if m_bits < 0 || m_bits > 64_000_000 {
    raise DbError::Corrupt("sst: bad bloom size")
  }
  let nbytes = (m_bits + 7) / 8
  if bpos.val + nbytes != fb {
    raise DbError::Corrupt("sst: trailing bytes in bloom")
  }
  let bloom = if m_bits == 0 {
    None
  } else {
    Some({ m_bits: m_bits, bits: bytes[bpos.val:bpos.val + nbytes].to_owned() })
  }
  {
    bytes: bytes,
    idx_off: idx_off,
    index_keys: keys,
    index_offsets: offs,
    bloom: bloom,
  }
}

/// The bloom filter says the key is absent, or the table has no filter (v1).
/// A `false` answer is authoritative; `true` only avoids a wasted lookup.
pub fn SstReader::may_contain(self : SstReader, key : Bytes) -> Bool {
  match self.bloom {
    None => true
    Some(b) => b.may_contain(key)
  }
}

/// Looks up a key. `None` = absent, `Some(None)` = tombstone, `Some(Some(v))`
/// = live value.
pub fn SstReader::get(self : SstReader, key : Bytes) -> Option[Option[Bytes]] raise DbError {
  let mut lo = 0
  let mut hi = self.index_keys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.index_keys[mid].lexical_compare(key) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo >= self.index_keys.length() {
    return None
  }
  let start = self.index_offsets[lo]
  let end = if lo + 1 < self.index_offsets.length() {
    self.index_offsets[lo + 1]
  } else {
    self.idx_off
  }
  let pos = Ref(start)
  let n = match try_varint(self.bytes, pos) {
    None => raise DbError::Corrupt("sst: bad block header")
    Some(v) => v.to_int()
  }
  for _i = 0; _i < n; _i = _i + 1 {
    let tomb = match try_varint(self.bytes, pos) {
      None => raise DbError::Corrupt("sst: bad entry")
      Some(v) => v.to_int()
    }
    let _seq = match try_varint(self.bytes, pos) {
      None => raise DbError::Corrupt("sst: bad entry seq")
      Some(v) => v
    }
    let kl = match try_varint(self.bytes, pos) {
      None => raise DbError::Corrupt("sst: bad entry key")
      Some(v) => v.to_int()
    }
    if kl < 0 || pos.val + kl > end {
      raise DbError::Corrupt("sst: entry key out of range")
    }
    let k = self.bytes[pos.val:pos.val + kl]
    pos.val = pos.val + kl
    let vl = match try_varint(self.bytes, pos) {
      None => raise DbError::Corrupt("sst: bad entry value")
      Some(v) => v.to_int()
    }
    if vl < 0 || pos.val + vl > end {
      raise DbError::Corrupt("sst: entry value out of range")
    }
    // vl == 0 means a tombstone only when the tomb flag is set; a live
    // entry with an empty value keeps Some(b"").
    let v = if tomb == 1 && vl == 0 {
      None
    } else {
      let view = self.bytes[pos.val:pos.val + vl]
      pos.val = pos.val + vl
      Some(view.to_owned())
    }
    let cmp = key.lexical_compare(k.to_owned())
    if cmp == 0 {
      return Some(v)
    }
    if cmp < 0 {
      return None
    }
  }
  None
}

/// A lazy forward cursor over one table: entries are parsed on demand, one
/// block at a time, so scanning a large file holds no extra materialized
/// state. Parse failures are reported through `error` rather than raised.
/// Every entry must be strictly greater than the previous one — a duplicate
/// or out-of-order key is a form of corruption that CRC cannot see (e.g. a
/// table written by a buggy old version), and it would otherwise be merged
/// silently forward by compactions. The cursor rejects it with `Corrupt`.
pub(all) struct SstCursor {
  reader : SstReader
  block_idx : Ref[Int]
  pos : Ref[Int]
  entries_left : Ref[Int]
  current : Ref[Option[Entry]]
  last_key : Ref[Option[Bytes]]
  done : Ref[Bool]
  err : Ref[Option[DbError]]
}

pub fn SstReader::cursor(self : SstReader) -> SstCursor {
  {
    reader: self,
    block_idx: Ref(0),
    pos: Ref(0),
    entries_left: Ref(0),
    current: Ref(None),
    last_key: Ref(None),
    done: Ref(false),
    err: Ref(None),
  }
}

fn SstCursor::fail(self : SstCursor, msg : String) -> Unit {
  self.err.val = Some(DbError::Corrupt(msg))
  self.done.val = true
}

fn SstCursor::load(self : SstCursor) -> Unit {
  if self.done.val || self.current.val is Some(_) || self.err.val is Some(_) {
    return
  }
  if self.entries_left.val == 0 {
    let i = self.block_idx.val
    if i >= self.reader.index_keys.length() {
      self.done.val = true
      return
    }
    let start = self.reader.index_offsets[i]
    self.pos.val = start
    match try_varint(self.reader.bytes, self.pos) {
      None => {
        self.fail("sst: bad block header")
        return
      }
      Some(n) => self.entries_left.val = n.to_int()
    }
    self.block_idx.val = i + 1
  }
  let tomb = match try_varint(self.reader.bytes, self.pos) {
    None => {
      self.fail("sst: bad entry")
      return
    }
    Some(v) => v.to_int()
  }
  let seq = match try_varint(self.reader.bytes, self.pos) {
    None => {
      self.fail("sst: bad entry seq")
      return
    }
    Some(v) => v
  }
  let kl = match try_varint(self.reader.bytes, self.pos) {
    None => {
      self.fail("sst: bad entry key")
      return
    }
    Some(v) => v.to_int()
  }
  if kl < 0 || pos_bound(self.pos.val, kl) > self.reader.bytes.length() {
    self.fail("sst: entry key out of range")
    return
  }
  let key = self.reader.bytes[self.pos.val:self.pos.val + kl].to_owned()
  self.pos.val = self.pos.val + kl
  // Strictly ascending keys: blocks may not repeat or regress (see the
  // struct comment). A single comparison per entry; the index already
  // guarantees block-level ordering, so one cursor-wide last key suffices.
  match self.last_key.val {
    Some(prev) => {
      if prev.lexical_compare(key) >= 0 {
        self.fail("sst: keys not strictly ascending")
        return
      }
    }
    None => ()
  }
  self.last_key.val = Some(key)
  let vl = match try_varint(self.reader.bytes, self.pos) {
    None => {
      self.fail("sst: bad entry value")
      return
    }
    Some(v) => v.to_int()
  }
  if vl < 0 || pos_bound(self.pos.val, vl) > self.reader.bytes.length() {
    self.fail("sst: entry value out of range")
    return
  }
  // Same rule as get: only tomb=1 with vl=0 is a tombstone.
  let value = if tomb == 1 && vl == 0 {
    None
  } else {
    let view = self.reader.bytes[self.pos.val:self.pos.val + vl]
    self.pos.val = self.pos.val + vl
    Some(view.to_owned())
  }
  self.entries_left.val = self.entries_left.val - 1
  self.current.val = Some({ key: key, seq: seq, value: value })
}

fn pos_bound(pos : Int, len : Int) -> Int {
  pos + len
}

pub fn SstCursor::peek(self : SstCursor) -> Option[Entry] {
  self.load()
  self.current.val
}

pub fn SstCursor::advance(self : SstCursor) -> Unit {
  self.current.val = None
}

pub fn SstCursor::error(self : SstCursor) -> Option[DbError] {
  self.err.val
}
