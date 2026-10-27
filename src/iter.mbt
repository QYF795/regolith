// iter.mbt
//
// The entry type shared by memtable, WAL and SSTable, and the LSM merge
// iterator used by `Db::scan`.
//
// The merge iterator pulls from any number of ordered sources (a memtable
// plus any number of table cursors). When several sources hold the same key
// the entry with the highest sequence number wins and the others are
// skipped; a winning tombstone suppresses the key entirely. Because every
// source reports its own I/O failures through `error`, a scan surfaces
// failures as a channel instead of raising mid-iteration.

pub(all) struct Entry {
  key : Bytes
  seq : UInt64
  value : Option[Bytes] // None = tombstone
}

pub(all) enum Stream {
  Mem(MemIter)
  Sst(SstCursor)
}

fn Stream::peek_entry(self : Stream) -> Option[Entry] {
  match self {
    Mem(m) => m.peek()
    Sst(c) => c.peek()
  }
}

fn Stream::advance(self : Stream) -> Unit {
  match self {
    Mem(m) => m.advance()
    Sst(c) => c.advance()
  }
}

fn Stream::error_of(self : Stream) -> Option[DbError] {
  match self {
    Mem(m) => m.error()
    Sst(c) => c.error()
  }
}

pub(all) struct MergeIterator {
  streams : Array[Stream]
  heads : Array[Option[Entry]]
  mut err : Option[DbError]
}

pub fn MergeIterator::new(streams : Array[Stream]) -> MergeIterator {
  let heads : Array[Option[Entry]] = []
  for _i = 0; _i < streams.length(); _i = _i + 1 {
    heads.push(None)
  }
  { streams, heads, err: None }
}

fn MergeIterator::load(self : MergeIterator, i : Int) -> Unit {
  if self.heads[i] is Some(_) {
    return
  }
  match self.streams[i].peek_entry() {
    Some(e) => self.heads[i] = Some(e)
    None => {
      if self.err is None {
        self.err = self.streams[i].error_of()
      }
    }
  }
}

/// Returns the next winning entry in ascending key order, tombstone or not.
/// Returns `None` when all sources are exhausted (or a source failed — check
/// `error`).
fn MergeIterator::next_raw(self : MergeIterator) -> Option[Entry] {
  if self.err is Some(_) {
    return None
  }
  let mut cont = true
  let mut out = None
  while cont && out is None {
    for i = 0; i < self.streams.length(); i = i + 1 {
      self.load(i)
    }
    if self.err is Some(_) {
      return None
    }
    let mut best_i = -1
    for i = 0; i < self.streams.length(); i = i + 1 {
      match self.heads[i] {
        None => continue
        Some(e) => {
          if best_i < 0 || e.key.lexical_compare(self.heads[best_i].unwrap().key) < 0 {
            best_i = i
          }
        }
      }
    }
    if best_i < 0 {
      cont = false
      continue
    }
    let best_key = self.heads[best_i].unwrap().key
    let mut winner_i = best_i
    let mut best_seq = self.heads[best_i].unwrap().seq
    for i = 0; i < self.streams.length(); i = i + 1 {
      match self.heads[i] {
        None => continue
        Some(e) => {
          if e.key == best_key && e.seq > best_seq {
            winner_i = i
            best_seq = e.seq
          }
        }
      }
    }
    let winner = self.heads[winner_i]
    for i = 0; i < self.streams.length(); i = i + 1 {
      match self.heads[i] {
        None => continue
        Some(e) => {
          if e.key == best_key {
            self.streams[i].advance()
            self.heads[i] = None
          }
        }
      }
    }
    match winner {
      None => continue
      Some(e) => out = Some(e)
    }
  }
  out
}

/// Returns the next live entry in ascending key order, skipping tombstones.
/// Returns `None` when all sources are exhausted (or a source failed — check
/// `error`).
pub fn MergeIterator::next(self : MergeIterator) -> Option[Entry] {
  let mut cont = true
  let mut out = None
  while cont && out is None {
    match self.next_raw() {
      None => cont = false
      Some(e) => {
        if e.value is Some(_) {
          out = Some(e)
        }
      }
    }
  }
  out
}

/// The first failure reported by any source, if any.
pub fn MergeIterator::error(self : MergeIterator) -> Option[DbError] {
  self.err
}


/// A merge iterator bounded to one key range [lo, hi). Skips keys below `lo`
/// and stops at the first key >= `hi` — keys arrive in ascending order, so no
/// in-range key can follow an out-of-range one. `scan_prefix` is the same
/// mechanism: lo = prefix, hi = the first key not starting with the prefix.
/// When no finite hi exists (a prefix of all 0xFF bytes), a fallback prefix
/// check plays the upper bound.
pub(all) struct RangeIterator {
  inner : MergeIterator
  lo : Bytes
  hi : Option[Bytes]
  prefix : Option[Bytes]
}

/// An iterator over [lo, hi); `hi = None` means no upper bound.
pub fn RangeIterator::new(
  inner : MergeIterator,
  lo : Bytes,
  hi : Option[Bytes]
) -> RangeIterator {
  { inner, lo, hi, prefix: None }
}

/// An iterator over every key that starts with `prefix` (see prefix_upper).
pub fn RangeIterator::new_prefix(inner : MergeIterator, prefix : Bytes) -> RangeIterator {
  match prefix_upper(prefix) {
    Some(hi) => { inner, lo: prefix, hi: Some(hi), prefix: None }
    None => { inner, lo: prefix, hi: None, prefix: Some(prefix) }
  }
}

/// The next live entry in the range, or `None` once the range is exhausted
/// (or a source failed — check `error`).
pub fn RangeIterator::next(self : RangeIterator) -> Option[Entry] {
  let mut cont = true
  let mut out = None
  while cont && out is None {
    match self.inner.next() {
      None => cont = false
      Some(e) => {
        if e.key.lexical_compare(self.lo) < 0 {
          continue
        }
        match self.hi {
          Some(h) => {
            if e.key.lexical_compare(h) >= 0 {
              cont = false
            } else {
              out = Some(e)
            }
          }
          None => {
            match self.prefix {
              Some(p) => {
                if has_prefix(e.key, p) {
                  out = Some(e)
                } else {
                  cont = false
                }
              }
              None => out = Some(e)
            }
          }
        }
      }
    }
  }
  out
}

/// The first failure reported by any underlying source, if any.
pub fn RangeIterator::error(self : RangeIterator) -> Option[DbError] {
  self.inner.error()
}

/// The smallest key that sorts after every key starting with `prefix` —
/// prefix with its last non-0xFF byte incremented. `None` when no finite
/// such key exists (empty prefix, or a prefix of all 0xFF bytes).
fn prefix_upper(prefix : Bytes) -> Option[Bytes] {
  if prefix.length() == 0 {
    return None
  }
  let mut i = prefix.length() - 1
  while i >= 0 && prefix[i].to_int() == 255 {
    i = i - 1
  }
  if i < 0 {
    return None
  }
  let buf = @buffer.Buffer(size_hint=prefix.length())
  buf.write_bytes(prefix[0:i])
  buf.write_byte((prefix[i].to_int() + 1).to_byte())
  Some(buf.to_bytes())
}

/// True when `key` starts with `prefix`, byte for byte.
fn has_prefix(key : Bytes, prefix : Bytes) -> Bool {
  if key.length() < prefix.length() {
    return false
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    if key[i] != prefix[i] {
      return false
    }
  }
  true
}
