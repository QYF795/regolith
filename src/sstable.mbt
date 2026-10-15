// sstable.mbt
//
// SSTable v1: the on-disk sorted table. Layout (see docs/format.md §3):
//
//   blocks* index footer
//   block  := count(varint) entry*
//   entry  := tomb(varint) seq(varint) kl(varint) key vl(varint) value
//   index  := m(varint) (kl(varint) last_key offset(varint))*
//   footer := idx_off(u64 LE) crc(u32 LE) crc2(u32 LE) magic("RGSST1")
//
// crc covers everything before the footer; crc2 covers the footer's offset
// and checksum fields, so a single flipped byte anywhere in the file makes
// the whole table unreadable — reads can never return silently wrong data.

const SST_MAGIC_V1 : String = "RGSST1"
const FOOTER_V1 : Int = 22

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

/// Builds an SSTable v1 from entries added in ascending key order.
pub(all) struct SstBuilder {
  data : @buffer.Buffer
  block : @buffer.Buffer
  index : @buffer.Buffer
  block_count : Ref[Int]
  index_count : Ref[Int]
  last_key : Ref[Option[Bytes]]
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
  if self.block.length() >= self.block_size {
    self.seal_block()
  }
}

/// Finishes the table and returns the serialized bytes.
pub fn SstBuilder::finish(self : SstBuilder) -> Bytes {
  self.seal_block()
  let idx_off = self.data.length()
  // The index is written after the blocks, prefixed with the block count.
  let final_index = @buffer.Buffer(size_hint=self.index.length() + 8)
  put_varint(final_index, self.index_count.val.to_uint64())
  final_index.write_bytes(self.index.to_bytes())
  self.data.write_bytes(final_index.to_bytes())
  let body = self.data.to_bytes()
  let footer = @buffer.Buffer(size_hint=32)
  write_u64_le(footer, idx_off.to_uint64())
  let crc = crc32(body)
  write_u32_le(footer, crc)
  let crc2 = crc32(footer.to_bytes())
  write_u32_le(footer, crc2)
  footer.write_bytes(b"RGSST1")
  body + footer.to_bytes()
}

/// A validated, read-only view of an SSTable file.
pub(all) struct SstReader {
  bytes : Bytes
  idx_off : Int
  index_keys : Array[Bytes]
  index_offsets : Array[Int]
}

/// Validates magic, both checksums and the index, then returns the reader.
pub fn parse(bytes : Bytes) -> SstReader raise DbError {
  let len = bytes.length()
  if len < FOOTER_V1 + 1 {
    raise DbError::Corrupt("sst: file too short")
  }
  let fb = len - FOOTER_V1
  for j = 0; j < 6; j = j + 1 {
    if bytes[fb + 16 + j].to_int() != SST_MAGIC_V1[j].to_int() {
      raise DbError::Corrupt("sst: bad magic")
    }
  }
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
    if prev_off >= 0 && prev_key.compare(key) >= 0 {
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
  }
}

/// Looks up a key. `None` = absent, `Some(None)` = tombstone, `Some(Some(v))`
/// = live value.
pub fn SstReader::get(self : SstReader, key : Bytes) -> Option[Option[Bytes]] raise DbError {
  let mut lo = 0
  let mut hi = self.index_keys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.index_keys[mid].compare(key) < 0 {
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
    let v = if vl == 0 {
      None
    } else {
      let view = self.bytes[pos.val:pos.val + vl]
      pos.val = pos.val + vl
      Some(view.to_owned())
    }
    let cmp = key.compare(k.to_owned())
    if cmp == 0 {
      return Some(if tomb == 1 { None } else { v })
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
pub(all) struct SstCursor {
  reader : SstReader
  block_idx : Ref[Int]
  pos : Ref[Int]
  entries_left : Ref[Int]
  current : Ref[Option[Entry]]
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
  let value = if vl == 0 {
    None
  } else {
    let view = self.reader.bytes[self.pos.val:self.pos.val + vl]
    self.pos.val = self.pos.val + vl
    Some(view.to_owned())
  }
  self.entries_left.val = self.entries_left.val - 1
  self.current.val = Some({ key: key, seq: seq, value: if tomb == 1 { None } else { value } })
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
