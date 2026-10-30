// sstable.mbt
//
// SSTable v3: the on-disk sorted table (v1/v2 files are still readable).
// Layout (see docs/format.md §4):
//
//   blocks* index bloom footer
//   v3 block  := entry* restarts
//   v3 entry  := shared(varint) unshared(varint) tomb(varint) seq(varint)
//                vl(varint) suffix(unshared) value(vl)
//   restarts  := off(u32 LE)* num_r(u32 LE)
//   v2 block  := count(varint) entry*     (v2 files still parse)
//   index  := m(varint) (kl(varint) last_key offset(varint))*
//   bloom  := n(varint) m_bits(varint) bits
//   footer := idx_off(u64 LE) bloom_off(u64 LE) crc(u32 LE) crc2(u32 LE)
//             magic("RGSST3")
//
// v3 blocks prefix-compress keys: an entry stores only the suffix past the
// shared prefix with the previous key, and every `restart_interval`-th entry
// is a restart point storing the full key (shared = 0). The restart offset
// array at the block tail turns in-block point lookups from a linear scan
// into a binary search. The bloom filter (k=7 double hashing, 10 bits per
// key) lets point reads skip tables that provably do not contain the key.
// crc covers everything before the footer; crc2 covers the whole v3 footer
// except the crc2 field itself — offsets, crc and magic (v2 files only cover
// the first 20 bytes) — so a single flipped byte anywhere in the file makes
// the whole table unreadable: reads can never return silently wrong data.

const SST_MAGIC_V1 : String = "RGSST1"
const SST_MAGIC_V2 : String = "RGSST2"
const SST_MAGIC_V3 : String = "RGSST3"
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

/// Length of the longest common prefix of two byte strings.
fn common_prefix_len(a : Bytes, b : Bytes) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < n && a[i] == b[i] {
    i = i + 1
  }
  i
}

/// Builds an SSTable v3 (prefix-compressed blocks) from entries added in
/// ascending key order.
pub(all) struct SstBuilder {
  data : @buffer.Buffer
  block : @buffer.Buffer
  index : @buffer.Buffer
  block_count : Ref[Int]
  index_count : Ref[Int]
  last_key : Ref[Option[Bytes]]
  bloom_hashes : Array[UInt]
  block_size : Int
  restart_interval : Int
  /// Previous reconstructed key inside the current block (None = first entry
  /// or a restart point, which store the full key).
  block_prev_key : Ref[Option[Bytes]]
  block_entries : Ref[Int]
  /// Block-relative offsets of restart points, flushed into the block tail.
  mut restart_offs : Array[Int]
}

pub fn SstBuilder::new(block_size~ : Int = 4096, restart_interval~ : Int = 16) -> SstBuilder {
  {
    data: @buffer.Buffer(size_hint=8192),
    block: @buffer.Buffer(size_hint=block_size),
    index: @buffer.Buffer(size_hint=256),
    block_count: Ref(0),
    index_count: Ref(0),
    last_key: Ref(None),
    bloom_hashes: [],
    block_size,
    restart_interval,
    block_prev_key: Ref(None),
    block_entries: Ref(0),
    restart_offs: [],
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
  // v3 block tail: restart offsets then their count (no count prefix; the
  // entry area ends where the restart array begins).
  for off in self.restart_offs {
    write_u32_le(self.block, off.reinterpret_as_uint())
  }
  write_u32_le(self.block, self.restart_offs.length().reinterpret_as_uint())
  self.data.write_bytes(self.block.to_bytes())
  self.index_count.val = self.index_count.val + 1
  self.block.reset()
  self.block_count.val = 0
  self.last_key.val = None
  self.block_prev_key.val = None
  self.block_entries.val = 0
  self.restart_offs = []
}

/// Adds one entry. Keys must be strictly ascending.
pub fn SstBuilder::add(self : SstBuilder, entry : Entry) -> Unit {
  if self.block_entries.val % self.restart_interval == 0 {
    // Restart point: record the offset and store the full key.
    self.restart_offs.push(self.block.length())
    self.block_prev_key.val = None
  }
  let kl = entry.key.length()
  let shared = match self.block_prev_key.val {
    None => 0
    Some(prev) => common_prefix_len(prev, entry.key)
  }
  put_varint(self.block, shared.to_uint64())
  put_varint(self.block, (kl - shared).to_uint64())
  put_varint(self.block, if entry.value is None { 1UL } else { 0UL })
  put_varint(self.block, entry.seq)
  let vl = match entry.value {
    None => 0
    Some(v) => v.length()
  }
  put_varint(self.block, vl.to_uint64())
  self.block.write_bytes(entry.key[shared:kl])
  match entry.value {
    None => ()
    Some(v) => self.block.write_bytes(v)
  }
  self.block_prev_key.val = Some(entry.key)
  self.block_entries.val = self.block_entries.val + 1
  self.block_count.val = self.block_count.val + 1
  self.last_key.val = Some(entry.key)
  self.bloom_hashes.push(crc32_init(entry.key, BLOOM_SEED))
  if self.block.length() >= self.block_size {
    self.seal_block()
  }
}

/// Byte size of everything written so far (blocks + index buffers). Used to
/// split a large merge into several tables of bounded size.
pub fn SstBuilder::approx_size(self : SstBuilder) -> Int {
  self.data.length() + self.block.length() + self.index.length()
}

/// Finishes the table and returns the serialized bytes (v3, with bloom).
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
  // v3: crc2 covers the whole footer except the crc2 field itself — at this
  // point the buffer holds exactly those bytes (offsets, crc, magic).
  // Flipping one magic byte would otherwise turn a v3 table into a "valid"
  // v2 table (same footer layout), silently handing the v2 block decoder
  // garbage bytes.
  footer.write_bytes(b"RGSST3")
  let crc2 = crc32(footer.to_bytes())
  let final_footer = @buffer.Buffer(size_hint=32)
  final_footer.write_bytes(footer.to_bytes()[0:20])
  write_u32_le(final_footer, crc2)
  final_footer.write_bytes(footer.to_bytes()[20:26])
  body + final_footer.to_bytes()
}

/// A validated, read-only view of an SSTable file.
pub(all) struct SstReader {
  bytes : Bytes
  idx_off : Int
  index_keys : Array[Bytes]
  index_offsets : Array[Int]
  bloom : Option[Bloom]
  /// True for v3 tables: data blocks are prefix-compressed with restart
  /// points, and in-block point lookups binary-search the restart array.
  v3 : Bool
}

/// Validates magic, both checksums and the index, then returns the reader.
/// v1 files (no bloom) and v2 files (uncompressed blocks) are still
/// accepted and behave exactly as before.
pub fn parse(bytes : Bytes) -> SstReader raise DbError {
  if bytes.length() < FOOTER_V1 {
    raise DbError::Corrupt("sst: file too short")
  }
  if magic_is(bytes, bytes.length() - 6, SST_MAGIC_V1) {
    parse_v1(bytes)
  } else if magic_is(bytes, bytes.length() - 6, SST_MAGIC_V2) {
    parse_v2(bytes)
  } else if magic_is(bytes, bytes.length() - 6, SST_MAGIC_V3) {
    parse_v3(bytes)
  } else {
    raise DbError::Corrupt("sst: bad magic")
  }
}

/// True when the table's magic is not one this version understands AND its
/// footer checksum validates — i.e. a fully-written table from a newer
/// format version. Recovery must refuse to open rather than silently delete
/// such files (which would destroy data on downgrade). A torn write has
/// garbage in the footer, so its crc2 virtually never validates (2⁻³²); even
/// if it did, the consequence is only a refused open, never data loss.
pub fn is_future_format(bytes : Bytes) -> Bool {
  if bytes.length() < FOOTER_V2 {
    return false
  }
  let at = bytes.length() - 6
  if magic_is(bytes, at, SST_MAGIC_V1) || magic_is(bytes, at, SST_MAGIC_V2) ||
    magic_is(bytes, at, SST_MAGIC_V3) {
    return false
  }
  let fb = bytes.length() - FOOTER_V2
  let crc2 = read_u32_le(bytes, fb + 20)
  // Accept either footer-checksum convention: v2 covered the 20 bytes before
  // the crc2 field, v3 also covers the magic. A future format using either
  // convention with an intact footer is recognized as a complete write.
  crc32(bytes[fb:fb + 20]) == crc2 || footer_crc2_v3(bytes, fb) == crc2
}

/// crc32 over the v3 footer minus the crc2 field itself: the offset and
/// checksum fields plus the magic. The writer computes crc2 over exactly
/// these bytes before the crc2 field exists; the reader reconstructs the
/// same byte sequence by skipping it.
fn footer_crc2_v3(bytes : Bytes, fb : Int) -> UInt {
  let f = @buffer.Buffer(size_hint=26)
  f.write_bytes(bytes[fb:fb + 20])
  f.write_bytes(bytes[fb + 24:fb + 30])
  crc32(f.to_bytes())
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
    v3: false,
  }
}

fn parse_v2(bytes : Bytes) -> SstReader raise DbError {
  parse_v2_or_v3(bytes, false)
}

/// v3 shares the v2 footer/index/bloom layout — only the block encoding
/// differs (see the file header).
fn parse_v3(bytes : Bytes) -> SstReader raise DbError {
  parse_v2_or_v3(bytes, true)
}

fn parse_v2_or_v3(bytes : Bytes, v3 : Bool) -> SstReader raise DbError {
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
  // v3's crc2 covers the whole footer except the crc2 field itself (offsets,
  // crc and magic), v2's covers only the first 20 bytes (kept for
  // compatibility with files written by 0.4.x). The mismatch either way
  // rejects magic flips between the two formats.
  let crc2_ok = if v3 {
    footer_crc2_v3(bytes, fb) == crc2
  } else {
    crc32(bytes[fb:fb + 20]) == crc2
  }
  if !crc2_ok {
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
    v3: v3,
  }
}

/// The smallest key in the table: the first entry of the first block. The
/// index only stores per-block *last* keys, so the first key is read from
/// the data. A table that fails this parse is corrupt.
pub fn SstReader::first_key(self : SstReader) -> Bytes raise DbError {
  if self.v3 {
    // First entry of a v3 block is a restart point — the empty previous key
    // makes decode_v3_entry enforce `shared == 0`, so the reconstructed key
    // is the suffix alone.
    return decode_v3_entry(self.bytes, Ref(0), self.idx_off, b"").key
  }
  let pos = Ref(0)
  let n = match try_varint(self.bytes, pos) {
    None => raise DbError::Corrupt("sst: bad block header")
    Some(v) => v.to_int()
  }
  if n < 1 {
    raise DbError::Corrupt("sst: empty first block")
  }
  // entry := tomb(varint) seq(varint) kl(varint) key vl(varint) value
  match try_varint(self.bytes, pos) {
    None => raise DbError::Corrupt("sst: bad entry")
    Some(_) => ()
  }
  match try_varint(self.bytes, pos) {
    None => raise DbError::Corrupt("sst: bad entry seq")
    Some(_) => ()
  }
  let kl = match try_varint(self.bytes, pos) {
    None => raise DbError::Corrupt("sst: bad entry key")
    Some(v) => v.to_int()
  }
  if kl < 0 || pos.val + kl > self.bytes.length() {
    raise DbError::Corrupt("sst: entry key out of range")
  }
  self.bytes[pos.val:pos.val + kl].to_owned()
}

/// The largest key in the table: the index stores each block's last key.
pub fn SstReader::max_key(self : SstReader) -> Bytes {
  self.index_keys[self.index_keys.length() - 1]
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
  if self.v3 {
    return self.get_v3(key, start, end)
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

/// Decodes and validates the restarts section of a v3 block `[start, end)`:
/// the offset array (strictly increasing, first == 0, inside the entry
/// area) and the keys at the restart points (strictly ascending, each a
/// full key). Returns the restart keys in order.
fn v3_restart_keys(bytes : Bytes, start : Int, end : Int) -> Array[Bytes] raise DbError {
  if end - start < 8 {
    raise DbError::Corrupt("sst: v3 block too short")
  }
  let num_r = read_u32_le(bytes, end - 4).reinterpret_as_int()
  if num_r < 1 || 4 * (num_r + 1) > end - start {
    raise DbError::Corrupt("sst: v3 bad restart count")
  }
  let rstart = end - 4 * (num_r + 1)
  let keys : Array[Bytes] = []
  let mut prev_off = -1
  let mut prev_key = b""
  for i = 0; i < num_r; i = i + 1 {
    let off = read_u32_le(bytes, rstart + 4 * i).reinterpret_as_int()
    if i == 0 && off != 0 {
      raise DbError::Corrupt("sst: v3 first restart is not at block start")
    }
    if off <= prev_off || off >= rstart - start {
      raise DbError::Corrupt("sst: v3 bad restart offset")
    }
    let k = restart_key(bytes, start + off, rstart)
    if i > 0 && prev_key.lexical_compare(k) >= 0 {
      raise DbError::Corrupt("sst: v3 restart keys not increasing")
    }
    prev_off = off
    prev_key = k
    keys.push(k)
  }
  keys
}

/// Decodes the key at a v3 restart point. Restart entries must store the
/// full key — delegating to the full entry decoder with an empty previous
/// key enforces `shared == 0`; `limit` bounds the entry area.
fn restart_key(bytes : Bytes, off : Int, limit : Int) -> Bytes raise DbError {
  decode_v3_entry(bytes, Ref(off), limit, b"").key
}

/// Decodes one v3 entry at `pos` (which must point at its start), advancing
/// `pos` past it. `prev` is the previous reconstructed key in the block —
/// for a restart point (shared == 0) its content does not matter. The entry
/// must fit entirely inside the entry area `limit`.
fn decode_v3_entry(
  bytes : Bytes,
  pos : Ref[Int],
  limit : Int,
  prev : Bytes
) -> Entry raise DbError {
  let shared = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: v3 bad shared prefix")
    Some(v) => v.to_int()
  }
  if shared < 0 || shared > prev.length() {
    raise DbError::Corrupt("sst: v3 shared prefix overruns previous key")
  }
  let unshared = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: v3 bad key suffix")
    Some(v) => v.to_int()
  }
  if unshared < 0 || pos.val + unshared > limit {
    raise DbError::Corrupt("sst: v3 key suffix out of range")
  }
  let tomb = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: v3 bad entry")
    Some(v) => v.to_int()
  }
  let seq = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: v3 bad entry seq")
    Some(v) => v
  }
  let vl = match try_varint(bytes, pos) {
    None => raise DbError::Corrupt("sst: v3 bad entry value")
    Some(v) => v.to_int()
  }
  if vl < 0 || pos.val + vl > limit {
    raise DbError::Corrupt("sst: v3 entry value out of range")
  }
  let suffix = bytes[pos.val:pos.val + unshared]
  pos.val = pos.val + unshared
  let value = if tomb == 1 && vl == 0 {
    None
  } else {
    let view = bytes[pos.val:pos.val + vl]
    pos.val = pos.val + vl
    Some(view.to_owned())
  }
  let key = if shared == 0 {
    suffix.to_owned()
  } else {
    prev[0:shared].to_owned() + suffix.to_owned()
  }
  { key: key, seq: seq, value: value }
}

/// In-block point lookup for v3 blocks: binary-search the restart array
/// (validated once), then scan at most `restart_interval` entries from the
/// chosen restart point.
fn SstReader::get_v3(
  self : SstReader,
  key : Bytes,
  start : Int,
  end : Int
) -> Option[Option[Bytes]] raise DbError {
  let rkeys = v3_restart_keys(self.bytes, start, end)
  let rstart = end - 4 * (read_u32_le(self.bytes, end - 4).reinterpret_as_int() + 1)
  // Upper bound over restart keys: first restart whose key > target.
  let mut lo = 0
  let mut hi = rkeys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if rkeys[mid].lexical_compare(key) > 0 {
      hi = mid
    } else {
      lo = mid + 1
    }
  }
  if lo == 0 {
    // Target sorts before the block's first key; the index lower bound
    // makes this impossible for a well-formed table, so this is an absent
    // key (or a corrupt index, which parse rejects at open time).
    return None
  }
  let pos = Ref(start + read_u32_le(self.bytes, rstart + 4 * (lo - 1)).reinterpret_as_int())
  let mut prev = rkeys[lo - 1]
  while pos.val < rstart {
    let e = decode_v3_entry(self.bytes, pos, rstart, prev)
    prev = e.key
    let cmp = e.key.lexical_compare(key)
    if cmp == 0 {
      return Some(e.value)
    }
    if cmp > 0 {
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
  /// End of the current block's entry area (v2: next block offset or index
  /// offset; v3: start of the restarts section). Entry bounds are checked
  /// against it, so no entry can spill into the next block.
  block_end : Ref[Int]
  /// Previous reconstructed key within the current v3 block (empty at block
  /// start — the first entry of every block is a restart point).
  prev_key : Ref[Bytes]
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
    block_end: Ref(0),
    prev_key: Ref(b""),
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
  if self.reader.v3 {
    self.load_v3()
  } else {
    self.load_v2()
  }
}

/// v2 blocks: count prefix + fixed entries. Key/value bounds are checked
/// against the block end rather than the whole file, so an entry cannot
/// spill into the next block.
fn SstCursor::load_v2(self : SstCursor) -> Unit {
  if self.entries_left.val == 0 {
    let i = self.block_idx.val
    if i >= self.reader.index_keys.length() {
      self.done.val = true
      return
    }
    let start = self.reader.index_offsets[i]
    let end = if i + 1 < self.reader.index_offsets.length() {
      self.reader.index_offsets[i + 1]
    } else {
      self.reader.idx_off
    }
    self.pos.val = start
    self.block_end.val = end
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
  if kl < 0 || pos_bound(self.pos.val, kl) > self.block_end.val {
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
  if vl < 0 || pos_bound(self.pos.val, vl) > self.block_end.val {
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

/// v3 blocks: prefix-compressed entries bounded by the restarts section.
fn SstCursor::load_v3(self : SstCursor) -> Unit {
  let bytes = self.reader.bytes
  if self.pos.val >= self.block_end.val {
    let i = self.block_idx.val
    if i >= self.reader.index_keys.length() {
      self.done.val = true
      return
    }
    let start = self.reader.index_offsets[i]
    let end = if i + 1 < self.reader.index_offsets.length() {
      self.reader.index_offsets[i + 1]
    } else {
      self.reader.idx_off
    }
    // Validate the restarts section once per block, then walk entries from
    // the block start (entry 0 is always a restart point, shared == 0).
    let _ = try {
      v3_restart_keys(bytes, start, end)
    } catch {
      _ => {
        self.fail("sst: v3 corrupt restart section")
        return
      }
    }
    let rstart = end - 4 * (read_u32_le(bytes, end - 4).reinterpret_as_int() + 1)
    self.pos.val = start
    self.block_end.val = rstart
    self.prev_key.val = b""
    self.block_idx.val = i + 1
  }
  let e = try {
    decode_v3_entry(bytes, self.pos, self.block_end.val, self.prev_key.val)
  } catch {
    _ => {
      self.fail("sst: v3 corrupt block")
      return
    }
  }
  match self.last_key.val {
    Some(prev) => {
      if prev.lexical_compare(e.key) >= 0 {
        self.fail("sst: keys not strictly ascending")
        return
      }
    }
    None => ()
  }
  self.last_key.val = Some(e.key)
  self.prev_key.val = e.key
  self.current.val = Some(e)
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
