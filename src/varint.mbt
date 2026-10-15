// varint.mbt
//
// Little-endian base-128 varints for UInt64, used by the WAL and SSTable
// encodings (see docs/format.md §1). Encoded lengths range from 1 byte
// (values below 128) to 10 bytes (full UInt64).

pub(all) suberror VarintError {
  Truncated
  Overflow
}

/// Appends the varint encoding of `v` to `buf`.
pub fn put_varint(buf : @buffer.Buffer, v : UInt64) -> Unit {
  let mut rest = v
  let mut cont = true
  while cont {
    if rest < 0x80UL {
      cont = false
    }
    let high = if cont { 0x80UL } else { 0UL }
    let byte = (rest & 0x7FUL) | high
    buf.write_byte(byte.to_int().to_byte())
    rest = rest >> 7
  }
}

/// Reads one varint from `bytes` starting at `pos.val`, advancing `pos` past
/// it. Raises `Truncated` if the input ends mid-varint and `Overflow` if the
/// encoding exceeds 10 bytes.
pub fn read_varint(bytes : Bytes, pos : Ref[Int]) -> UInt64 raise VarintError {
  let mut result = 0UL
  let mut shift = 0
  let mut i = pos.val
  let mut cont = true
  while cont {
    if i >= bytes.length() {
      raise VarintError::Truncated
    }
    if shift >= 70 {
      raise VarintError::Overflow
    }
    let b = bytes[i].to_int()
    cont = (b & 0x80) != 0
    result = result | ((b & 0x7F).reinterpret_as_uint().to_uint64() << shift)
    shift += 7
    i += 1
  }
  pos.val = i
  result
}
