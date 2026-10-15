/// CRC-32 check values from the canonical catalogue (zlib / PNGOUT vectors).
test "crc32_known_vectors" {
  assert_eq(crc32(b""), 0U)
  assert_eq(crc32(b"a"), 0xE8B7BE43U)
  assert_eq(crc32(b"abc"), 0x352441C2U)
  assert_eq(crc32(b"123456789"), 0xCBF43926U)
  assert_eq(crc32(b"hello world"), 0x0D4A1185U)
}

/// The CRC must agree on a slice view and the equivalent standalone bytes.
test "crc32_over_views" {
  let whole = b"prefix|hello world|suffix"
  assert_eq(crc32(whole[7:18]), crc32(b"hello world"))
}

/// Seeded streams are deterministic and distinct from the standard stream.
test "crc32_seeded" {
  let data = b"regolith"
  assert_eq(crc32_init(data, 1U), crc32_init(data, 1U))
  assert_true(crc32_init(data, 1U) != crc32_init(data, 2U))
  assert_true(crc32_init(data, 1U) != crc32(data))
}
