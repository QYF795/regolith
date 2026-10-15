// wal.mbt
//
// The write-ahead log. x/fs only offers whole-file IO (no append, no
// fsync), so the WAL is a group commit: `put`/`delete` append encoded
// records to an in-memory buffer, and `Db::flush` writes the whole buffer
// to the storage as one file, then clears it once the memtable has been
// sealed into an SSTable.
//
// Record layout (see docs/format.md §4):
//
//   record  := len(varint) crc(u32 LE) payload
//   payload := op(1B) seq(varint) kl(varint) key vl(varint) value
//   op      := 1 (put) | 2 (delete; vl is always 0)
//
// Recovery reads records in order and stops at the first one whose length
// or checksum does not check out — the torn tail of an interrupted write —
// treating the valid prefix as the log.

pub(all) struct Wal {
  buf : @buffer.Buffer
}

pub(all) struct WalRecord {
  key : Bytes
  value : Option[Bytes]
  seq : UInt64
}

pub fn Wal::new() -> Wal {
  { buf: @buffer.Buffer(size_hint=4096) }
}

/// Rebuilds the WAL buffer from bytes recovered from storage, so the next
/// seal rewrites the surviving records along with any new ones.
pub fn Wal::from_bytes(bytes : BytesView) -> Wal {
  { buf: @buffer.from_bytes(bytes) }
}

pub fn Wal::append(self : Wal, key : Bytes, value : Option[Bytes], seq : UInt64) -> Unit {
  let payload = @buffer.Buffer(size_hint=64)
  let op = if value is None { 2 } else { 1 }
  payload.write_byte(op.to_byte())
  put_varint(payload, seq)
  put_varint(payload, key.length().to_uint64())
  payload.write_bytes(key)
  match value {
    None => put_varint(payload, 0UL)
    Some(v) => {
      put_varint(payload, v.length().to_uint64())
      payload.write_bytes(v)
    }
  }
  let p = payload.to_bytes()
  put_varint(self.buf, p.length().to_uint64())
  write_u32_le(self.buf, crc32(p))
  self.buf.write_bytes(p)
}

pub fn Wal::encode(self : Wal) -> Bytes {
  self.buf.to_bytes()
}

pub fn Wal::clear(self : Wal) -> Unit {
  self.buf.reset()
}

pub fn Wal::is_empty(self : Wal) -> Bool {
  self.buf.is_empty()
}

pub fn Wal::length(self : Wal) -> Int {
  self.buf.length()
}

/// Parses a WAL image into records plus the length of the valid prefix.
/// Parsing stops cleanly at the first torn or corrupted record.
pub fn parse_wal(bytes : Bytes) -> (Array[WalRecord], Int) {
  let pos = Ref(0)
  let records : Array[WalRecord] = []
  let mut cont = true
  while cont && pos.val < bytes.length() {
    let start = pos.val
    let len = match try_varint(bytes, pos) {
      None => {
        cont = false
        continue
      }
      Some(v) => v.to_int()
    }
    // Smallest payload: op(1) + seq(1) + kl(1) + key(1) + vl(1).
    if len < 5 || pos.val + 4 + len > bytes.length() {
      pos.val = start
      cont = false
      continue
    }
    let payload = bytes[pos.val + 4:pos.val + 4 + len]
    let crc = read_u32_le(bytes, pos.val)
    pos.val = pos.val + 4 + len
    if crc32(payload) != crc {
      pos.val = start
      cont = false
      continue
    }
    let record = match decode_payload(payload) {
      None => {
        pos.val = start
        cont = false
        continue
      }
      Some(r) => r
    }
    records.push(record)
  }
  (records, pos.val)
}

fn decode_payload(payload : BytesView) -> Option[WalRecord] {
  let op = payload[0].to_int()
  if op != 1 && op != 2 {
    return None
  }
  let owned = payload.to_owned()
  let p = Ref(1)
  let seq = match try_varint(owned, p) {
    None => return None
    Some(v) => v
  }
  let kl = match try_varint(owned, p) {
    None => return None
    Some(v) => v.to_int()
  }
  if kl < 0 || p.val + kl > payload.length() {
    return None
  }
  let key = payload[p.val:p.val + kl].to_owned()
  p.val = p.val + kl
  let vl = match try_varint(owned, p) {
    None => return None
    Some(v) => v.to_int()
  }
  if vl < 0 || p.val + vl > payload.length() {
    return None
  }
  let value = if vl == 0 {
    None
  } else {
    let view = payload[p.val:p.val + vl]
    p.val = p.val + vl
    Some(view.to_owned())
  }
  if op == 2 && value is Some(_) {
    return None
  }
  Some({ key, seq, value })
}
