/// Golden encodings from the LEB128 reference vectors.
test "varint_golden_encodings" {
  let cases : Array[(UInt64, Array[Int])] = [
    (0UL, [0]),
    (1UL, [1]),
    (127UL, [0x7F]),
    (128UL, [0x80, 1]),
    (300UL, [0xAC, 2]),
    (16384UL, [0x80, 0x80, 1]),
    (
      18446744073709551615UL,
      [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1],
    ),
  ]
  for (v, want) in cases {
    let buf = @buffer.Buffer(size_hint=16)
    put_varint(buf, v)
    assert_eq(buf.length(), want.length())
    for i = 0; i < want.length(); i = i + 1 {
      assert_eq(buf.to_bytes()[i].to_int(), want[i])
    }
  }
}

test "varint_round_trip" {
  let values = [
    0UL,
    1UL,
    42UL,
    127UL,
    128UL,
    255UL,
    300UL,
    16383UL,
    16384UL,
    4294967295UL,
    4294967296UL,
    9223372036854775807UL,
    18446744073709551615UL,
  ]
  for v in values {
    let buf = @buffer.Buffer(size_hint=16)
    put_varint(buf, v)
    let pos = Ref(0)
    assert_eq(read_varint(buf.to_bytes(), pos), v)
    assert_eq(pos.val, buf.length())
  }
}

test "varint_read_truncated_raises" {
  let truncated = [b"\x80", b"\xFF\xFF\xFF"]
  for bytes in truncated {
    try {
      let pos = Ref(0)
      let _ = read_varint(bytes, pos)
      abort("expected VarintError::Truncated")
    } catch {
      VarintError::Truncated => ()
      _ => abort("expected VarintError::Truncated")
    }
  }
}

test "varint_read_overflow_raises" {
  let eleven = b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01"
  try {
    let pos = Ref(0)
    let _ = read_varint(eleven, pos)
    abort("expected VarintError::Overflow")
  } catch {
    VarintError::Overflow => ()
    _ => abort("expected VarintError::Overflow")
  }
}
