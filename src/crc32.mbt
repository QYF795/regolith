// crc32.mbt
//
// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320, init 0xFFFFFFFF,
// final xor 0xFFFFFFFF) over byte views. Used for WAL record checksums and
// SSTable integrity (see docs/format.md §2).
//
// `crc32_init` exposes the init seed; SSTable v2 bloom filters reuse it as a
// seeded hash for double hashing.

let crc_table : Array[UInt] = {
  let table : Array[UInt] = []
  for i = 0; i < 256; i = i + 1 {
    let mut c = i.reinterpret_as_uint()
    for _j = 0; _j < 8; _j = _j + 1 {
      if (c & 1U) == 1U {
        c = 0xEDB88320U ^ (c >> 1)
      } else {
        c = c >> 1
      }
    }
    table.push(c)
  }
  table
}

/// CRC-32 of `data` with the standard init and final-xor values.
pub fn crc32(data : BytesView) -> UInt {
  crc32_init(data, 0xFFFFFFFFU)
}

/// CRC-32 of `data` with a custom init seed (final xor still applied). The
/// seed selects an independent hash stream, which the bloom filter uses for
/// double hashing.
pub fn crc32_init(data : BytesView, init : UInt) -> UInt {
  let mut c = init
  for i = 0; i < data.length(); i = i + 1 {
    let idx = (c ^ data[i].to_int().reinterpret_as_uint()) & 0xFFU
    c = crc_table[idx.reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}
