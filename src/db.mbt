// db.mbt
//
// The embedded KV engine. One Db = one Storage, holding:
//
//   memtable  — skip list of the newest writes (never flushed to a table yet)
//   WAL       — group-commit log of those same writes, buffered in memory and
//               sealed to storage as one whole file on flush
//   L0        — tables flushed from the memtable, one per flush
//   L1        — at most one full-merge compaction output table
//
// Recovery (docs/format.md §6, docs/acceptance.md §8):
//   * every surviving table must pass SST validation; torn ones are dropped
//   * the newest L1 (largest S) subsumes every table entry with seq <= S —
//     such L0 tables are dropped entirely and WAL records <= S are skipped,
//     so a replayed database is exactly "checkpoint ∪ one WAL prefix"
//   * WAL records are replayed into the memtable; the torn tail of the WAL
//     file is truncated to the last valid record
//
// Flush order (the crash-safety core): seal WAL to storage first, then build
// and write the table, then clear the WAL, then swap the memtable. At every
// crash point the database recovers to checkpoint ∪ some op-prefix.

pub(all) struct Db {
  storage : Storage
  opts : Options
  mut memtable : MemTable
  mut wal : Wal
  next_seq : Ref[UInt64]
  l0_counter : Ref[Int]
  l0_names : Ref[Array[String]]
  l0_readers : Ref[Array[SstReader]]
  l1_seq : Ref[Option[UInt64]]
  l1_name : Ref[Option[String]]
  l1_reader : Ref[Option[SstReader]]
}

/// Opens a database over the given storage, recovering its state.
pub fn Db::open_with_options(storage : Storage, opts : Options) -> Db raise DbError {
  ensure_ready(storage)
  let db : Db = {
    storage: storage,
    opts: opts,
    memtable: MemTable::new(),
    wal: Wal::new(),
    next_seq: Ref(0UL),
    l0_counter: Ref(0),
    l0_names: Ref([]),
    l0_readers: Ref([]),
    l1_seq: Ref(None),
    l1_name: Ref(None),
    l1_reader: Ref(None),
  }
  db.recover()
  db
}

/// Opens a database rooted at a directory on the local filesystem.
pub fn Db::open(dir : String) -> Db raise DbError {
  Db::open_with_options(Storage::File(FileStorage::new(dir)), Options::default())
}

/// Opens an in-memory database (tests and embedders).
pub fn Db::open_memory() -> Db raise DbError {
  Db::open_with_options(Storage::Memory(MemoryStorage::new()), Options::default())
}

/// Writes a key. A later `put` or `delete` of the same key supersedes it.
pub fn Db::put(self : Db, key : Bytes, value : Bytes) -> Unit raise DbError {
  let seq = self.next_seq.val
  self.next_seq.val = seq + 1UL
  self.memtable.put(key, Some(value), seq)
  self.wal.append(key, Some(value), seq)
  if self.memtable.size_bytes() >= self.opts.memtable_limit {
    self.flush()
  }
}

/// Deletes a key (a tombstone write).
pub fn Db::delete(self : Db, key : Bytes) -> Unit raise DbError {
  let seq = self.next_seq.val
  self.next_seq.val = seq + 1UL
  self.memtable.put(key, None, seq)
  self.wal.append(key, None, seq)
  if self.memtable.size_bytes() >= self.opts.memtable_limit {
    self.flush()
  }
}

/// Reads a key: `None` absent, `Some(None)` deleted, `Some(Some(v))` live.
pub fn Db::get(self : Db, key : Bytes) -> Option[Option[Bytes]] raise DbError {
  match self.memtable.get(key) {
    Some(v) => return Some(v)
    None => ()
  }
  // Bloom filters let us skip tables that provably do not contain the key.
  let n = self.l0_readers.val.length()
  for i = n - 1; i >= 0; i = i - 1 {
    let r = self.l0_readers.val[i]
    if r.may_contain(key) {
      match r.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  match self.l1_reader.val {
    Some(r) => {
      if r.may_contain(key) {
        r.get(key)
      } else {
        None
      }
    }
    None => None
  }
}

/// Returns a merge iterator over all live entries, in ascending key order.
pub fn Db::scan(self : Db) -> MergeIterator {
  let streams : Array[Stream] = []
  streams.push(Stream::Mem(self.memtable.iter()))
  for r in self.l0_readers.val {
    streams.push(Stream::Sst(r.cursor()))
  }
  match self.l1_reader.val {
    Some(r) => streams.push(Stream::Sst(r.cursor()))
    None => ()
  }
  MergeIterator::new(streams)
}

/// Scans every live entry whose key starts with `prefix`, in ascending key
/// order. Stops early at the first key outside the prefix, so iterating a
/// small key range does not walk the whole store.
pub fn Db::scan_prefix(self : Db, prefix : Bytes) -> PrefixIterator {
  PrefixIterator::new(self.scan(), prefix)
}

/// Seals the memtable into an L0 table (see the header comment for order).
pub fn Db::flush(self : Db) -> Unit raise DbError {
  if self.memtable.is_empty() {
    // Nothing to seal; make sure the WAL on disk matches the (empty) buffer.
    if !self.wal.is_empty() {
      self.wal.clear()
      write(self.storage, "WAL", self.wal.encode())
    }
    return
  }
  // 1. Seal the WAL: every write we are about to table is durable first.
  write(self.storage, "WAL", self.wal.encode())
  // 2. Build the table from the memtable.
  let builder = SstBuilder::new(block_size=self.opts.block_size)
  let mi = self.memtable.iter()
  while true {
    match mi.peek() {
      None => break
      Some(e) => {
        builder.add(e)
        mi.advance()
      }
    }
  }
  let bytes = builder.finish()
  // 3. Write the table (validate it immediately after).
  let name = "L0_\{six(self.l0_counter.val)}.sst"
  write(self.storage, name, bytes)
  let reader = parse(bytes)
  self.l0_names.val.push(name)
  self.l0_readers.val.push(reader)
  self.l0_counter.val = self.l0_counter.val + 1
  // 4. Clear the WAL on disk; the memtable is now durable in the table.
  self.wal.clear()
  write(self.storage, "WAL", self.wal.encode())
  // 5. Swap in a fresh memtable.
  self.memtable = MemTable::new()
  // 6. Compaction once enough L0 tables have piled up.
  if self.l0_names.val.length() >= self.opts.l0_compaction_trigger {
    self.compact()
  }
}

/// Full-merges the memtable, every L0 table and the current L1 into a single
/// L1_<S> table, where S is the largest sequence number it contains. The new
/// table is written and validated before any old file is removed.
pub fn Db::compact(self : Db) -> Unit raise DbError {
  let streams : Array[Stream] = []
  streams.push(Stream::Mem(self.memtable.iter()))
  for r in self.l0_readers.val {
    streams.push(Stream::Sst(r.cursor()))
  }
  match self.l1_reader.val {
    Some(r) => streams.push(Stream::Sst(r.cursor()))
    None => ()
  }
  let it = MergeIterator::new(streams)
  let builder = SstBuilder::new(block_size=self.opts.block_size)
  let mut max_seq = 0UL
  let mut any = false
  while true {
    match it.next() {
      None => break
      Some(e) => {
        if e.seq > max_seq {
          max_seq = e.seq
        }
        builder.add(e)
        any = true
      }
    }
  }
  match it.error() {
    Some(err) => raise err
    None => ()
  }
  // The merge iterator suppresses tombstones; under a full merge that is
  // sound: the old tables are deleted after the new one lands, so there is
  // nothing left for a dropped tombstone to cover.
  let old_names : Array[String] = []
  for n in self.l0_names.val {
    old_names.push(n)
  }
  let old_l1 = self.l1_name.val
  if any {
    let s = max_seq
    let name = "L1_\{s}.sst"
    let bytes = builder.finish()
    write(self.storage, name, bytes)
    let reader = parse(bytes)
    for n in old_names {
      remove(self.storage, n)
    }
    match old_l1 {
      Some(n) => remove(self.storage, n)
      None => ()
    }
    self.l0_names.val = []
    self.l0_readers.val = []
    self.l1_seq.val = Some(s)
    self.l1_name.val = Some(name)
    self.l1_reader.val = Some(reader)
  } else {
    // Everything merged away (all tombstones). There is no table to write,
    // so just drop the old files; recovery without a new L1 keeps any
    // surviving old tables, whose tombstones still read correctly.
    for n in old_names {
      remove(self.storage, n)
    }
    match old_l1 {
      Some(n) => remove(self.storage, n)
      None => ()
    }
    self.l0_names.val = []
    self.l0_readers.val = []
    self.l1_seq.val = None
    self.l1_name.val = None
    self.l1_reader.val = None
  }
}

/// Flushes any pending writes; safe to call any number of times.
pub fn Db::close(self : Db) -> Unit raise DbError {
  self.flush()
}

pub fn Db::stats(self : Db) -> Stats {
  {
    memtable_bytes: self.memtable.size_bytes(),
    wal_bytes: self.wal.length(),
    l0_files: self.l0_names.val.length(),
    l1_files: if self.l1_reader.val is Some(_) { 1 } else { 0 },
  }
}

/// Restores Db state from storage. See the header comment for the rules.
fn Db::recover(self : Db) -> Unit raise DbError {
  let l0_names = list(self.storage, "L0_")
  let l1_names = list(self.storage, "L1_")
  // Newest valid L1 wins: larger S subsumes smaller.
  let mut best_s = 0UL
  let mut best_name = ""
  let mut best_reader : Option[SstReader] = None
  for name in l1_names {
    match parse_decimal(name, 3, name.length() - 7) {
      None => remove(self.storage, name)
      Some(s) => match read(self.storage, name) {
        None => ()
        Some(bytes) => {
          let parsed = try {
            Some(parse(bytes))
          } catch {
            _ => None
          }
          match parsed {
            None => remove(self.storage, name)
            Some(r) => {
              if s > best_s {
                best_s = s
                best_name = name
                best_reader = Some(r)
              }
            }
          }
        }
      }
    }
  }
  for name in l1_names {
    if name != best_name {
      remove(self.storage, name)
    }
  }
  // L0 tables: drop torn ones, and drop tables fully covered by L1.
  let mut max_l0_num = -1
  let mut max_table_seq = best_s
  for name in l0_names {
    match parse_decimal(name, 3, name.length() - 7) {
      None => {
        remove(self.storage, name)
        continue
      }
      Some(num) => {
        let n = num.to_int()
        if n > max_l0_num {
          max_l0_num = n
        }
        match read(self.storage, name) {
          None => ()
          Some(bytes) => {
            let parsed = try {
              Some(parse(bytes))
            } catch {
              _ => None
            }
            match parsed {
              None => remove(self.storage, name)
              Some(r) => {
                let m = max_seq_of(r)
                let covered = best_reader is Some(_) && m <= best_s
                if covered {
                  remove(self.storage, name)
                } else {
                  if m > max_table_seq {
                    max_table_seq = m
                  }
                  self.l0_names.val.push(name)
                  self.l0_readers.val.push(r)
                }
              }
            }
          }
        }
      }
    }
  }
  self.l0_counter.val = max_l0_num + 1
  match best_reader {
    Some(r) => {
      self.l1_seq.val = Some(best_s)
      self.l1_name.val = Some(best_name)
      self.l1_reader.val = Some(r)
    }
    None => ()
  }
  // WAL: replay the valid prefix; skip records the L1 already covers.
  match read(self.storage, "WAL") {
    None => ()
    Some(bytes) => {
      let (records, valid) = parse_wal(bytes)
      self.wal = Wal::from_bytes(bytes[0:valid])
      if valid < bytes.length() {
        write(self.storage, "WAL", bytes[0:valid].to_owned())
      }
      for r in records {
        if best_reader is Some(_) && r.seq <= best_s {
          continue
        }
        self.memtable.put(r.key, r.value, r.seq)
      }
    }
  }
  // The next sequence must clear everything recovered: the tables (L1's S
  // and every surviving L0), plus anything replayed from the WAL.
  let mem_seq = self.memtable.max_seq()
  let top = if mem_seq > max_table_seq { mem_seq } else { max_table_seq }
  self.next_seq.val = top + 1UL
}

/// The largest seq present in a table (used to test L1 coverage on recovery).
fn max_seq_of(reader : SstReader) -> UInt64 {
  let c = reader.cursor()
  let mut m = 0UL
  while true {
    match c.peek() {
      None => break
      Some(e) => {
        if e.seq > m {
          m = e.seq
        }
        c.advance()
      }
    }
  }
  m
}

/// Zero-padded 6-digit counter for L0 file names.
fn six(n : Int) -> String {
  let s = n.to_string()
  let mut out = ""
  for _i = s.length(); _i < 6; _i = _i + 1 {
    out = out + "0"
  }
  out + s
}

/// Parses a decimal number of exactly `len` digits starting at `at`.
fn parse_decimal(s : String, at : Int, len : Int) -> Option[UInt64] {
  if len < 0 || at < 0 || at + len > s.length() {
    return None
  }
  let mut v = 0UL
  for i = 0; i < len; i = i + 1 {
    let c = s[at + i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10UL + (c - 48).reinterpret_as_uint().to_uint64()
  }
  Some(v)
}
