// snapshot.mbt
//
// Snapshot: a point-in-time consistent view of the database — the "iterator
// handle" promised for M3. Creating one freezes the current state: the
// memtable is copied in full and the current L0/L1/L2 table readers are
// captured, so reads and iterators on the snapshot never change no matter
// what the live Db does afterwards (puts, deletes, flushes, compactions).
//
// Why a plain copy is correct, with no sequence filtering:
//   * every entry in the memtable at snapshot time has seq <= the snapshot
//     watermark (it is the watermark), and the copy is never touched again;
//   * every table captured at snapshot time was built from entries with seq
//     strictly before the snapshot, and its parsed reader is immutable.
// So the snapshot IS the database state at creation time — filtering by
// sequence number is unnecessary.
//
// Self-containment: every SstReader holds the full table bytes in memory,
// so a snapshot never reads a table *file*. Compaction deletes the files it
// merges away immediately, snapshot or no snapshot — deferring a deletion
// would leave a stale file for the next open to misclassify (resurrected
// keys, get/scan divergence). A snapshot that is never closed costs memory
// only.
//
// Iterators on a snapshot are stable handles: hold one across writes,
// flushes and compactions of the live Db and it keeps yielding the frozen
// view. Pausing is just stopping the loop; to resume at a key, open a
// scan_range from that key on the same snapshot.

pub(all) struct Snapshot {
  mem : MemTable
  l0_readers : Array[SstReader]
  l1_readers : Array[SstReader]
  l2_readers : Array[SstReader]
}

/// Creates a snapshot of the database's current state. The snapshot keeps
/// working (and keeps seeing the same data) while the Db keeps mutating.
pub fn Db::snapshot(self : Db) -> Snapshot {
  let mem = MemTable::new()
  let mi = self.memtable.iter()
  while true {
    match mi.peek() {
      None => break
      Some(e) => {
        mem.put(e.key, e.value, e.seq)
        mi.advance()
      }
    }
  }
  let l0_readers : Array[SstReader] = []
  for r in self.l0_readers.val {
    l0_readers.push(r)
  }
  let l1_readers : Array[SstReader] = []
  for t in self.l1_tables.val {
    l1_readers.push(t.reader)
  }
  let l2_readers : Array[SstReader] = []
  for t in self.l2_tables.val {
    l2_readers.push(t.reader)
  }
  { mem: mem, l0_readers: l0_readers, l1_readers: l1_readers, l2_readers: l2_readers }
}

/// Reads a key as of snapshot creation: `None` absent, `Some(None)`
/// deleted, `Some(Some(v))` live.
pub fn Snapshot::get(self : Snapshot, key : Bytes) -> Option[Option[Bytes]] raise DbError {
  match self.mem.get(key) {
    Some(v) => return Some(v)
    None => ()
  }
  let n = self.l0_readers.length()
  for i = n - 1; i >= 0; i = i - 1 {
    let r = self.l0_readers[i]
    if r.may_contain(key) {
      match r.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  for r in self.l1_readers {
    if r.may_contain(key) {
      match r.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  for r in self.l2_readers {
    if r.may_contain(key) {
      match r.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  None
}

/// Iterates the frozen view in ascending key order. The iterator stays
/// valid while the live Db mutates — a stable handle.
pub fn Snapshot::scan(self : Snapshot) -> MergeIterator {
  let streams : Array[Stream] = []
  streams.push(Stream::Mem(self.mem.iter()))
  for r in self.l0_readers {
    streams.push(Stream::Sst(r.cursor()))
  }
  for r in self.l1_readers {
    streams.push(Stream::Sst(r.cursor()))
  }
  for r in self.l2_readers {
    streams.push(Stream::Sst(r.cursor()))
  }
  MergeIterator::new(streams)
}

/// Prefix scan over the frozen view; see `Db::scan_prefix`.
pub fn Snapshot::scan_prefix(self : Snapshot, prefix : Bytes) -> RangeIterator {
  RangeIterator::new_prefix(self.scan(), prefix)
}

/// Range scan over the frozen view; see `Db::scan_range`. Pausing an
/// iteration and resuming from the last seen key = calling this again with
/// `start` = that key (or its successor).
pub fn Snapshot::scan_range(self : Snapshot, start : Bytes, end : Option[Bytes]) -> RangeIterator {
  RangeIterator::new(self.scan(), start, end)
}

/// Releases the snapshot. Idempotent. Snapshots are self-contained
/// in-memory views — there are no table files to reclaim, so close only
/// marks the handle as done; reads keep working afterwards. The method is
/// kept for API stability: existing callers keep compiling, and future
/// snapshots that hold real resources can release them here.
pub fn Snapshot::close(_self : Snapshot) -> Unit {
}
