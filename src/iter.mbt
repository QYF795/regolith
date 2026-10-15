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

/// Returns the next live entry in ascending key order, skipping tombstones.
/// Returns `None` when all sources are exhausted (or a source failed — check
/// `error`).
pub fn MergeIterator::next(self : MergeIterator) -> Option[Entry] {
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
          if best_i < 0 || e.key.compare(self.heads[best_i].unwrap().key) < 0 {
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
