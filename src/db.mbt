// db.mbt
//
// The embedded KV engine. One Db = one Storage, holding:
//
//   memtable  — skip list of the newest writes (never flushed to a table yet)
//   WAL       — group-commit log of those same writes, buffered in memory and
//               sealed to storage as one whole file on flush
//   L0        — tables flushed from the memtable, one per flush
//   L1        — any number of compaction output tables with pairwise disjoint
//               key ranges, named L1_<S>_<G>.sst (S = max seq, G = a global
//               table counter). Non-bottom: tombstones are retained.
//   L2        — any number of bottom tables with pairwise disjoint key
//               ranges, named L2_<S>_<G>.sst. Tombstones are suppressed
//               (every older version is in the merge).
//
// Compaction (docs/design-multifile.md):
//   * compact    L0 → L1: every L0 table plus the L1 tables whose ranges
//                overlap the L0 span; the merge is split into tables of at
//                most opts.table_size_limit bytes.
//   * compact_l2 L1 → L2: the oldest L1 table plus every L1/L2 table whose
//                range overlaps it; tombstones are suppressed.
//   * inputs are deleted oldest-first (ascending S) after the new tables
//     land, so any crash prefix keeps the newest copies on disk.
//
// Recovery (docs/format.md §6): every valid table is kept (keep-all for L1);
// a table is dropped only when a span union of newer tables provably covers
// it (L2 by L2, L0 by L1, plus legacy-format rules). The WAL is replayed in
// full — within one WAL later records supersede earlier ones, so the
// memtable always ends up with the newest version of every key.
//
// Flush order (the crash-safety core): seal WAL to storage first, then build
// and write the table, then clear the WAL, then swap the memtable. At every
// crash point the database recovers to checkpoint ∪ some op-prefix.

/// One L1/L2 table: file name, validated reader and key-range metadata.
/// `seq` is the table's watermark S (its largest sequence number).
pub(all) struct Table {
  name : String
  reader : SstReader
  seq : UInt64
  min_key : Bytes
  max_key : Bytes
  bytes : Int
}

pub(all) struct Db {
  storage : Storage
  opts : Options
  mut memtable : MemTable
  mut wal : Wal
  next_seq : Ref[UInt64]
  l0_counter : Ref[Int]
  l0_names : Ref[Array[String]]
  l0_readers : Ref[Array[SstReader]]
  l1_tables : Ref[Array[Table]]
  l2_tables : Ref[Array[Table]]
  table_gen : Ref[Int]
  l1_bytes : Ref[Int]
  l2_bytes : Ref[Int]
  snapshots : Ref[Array[Snapshot]]
  next_snap_id : Ref[UInt64]
  pending : Ref[Array[String]]
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
    l1_tables: Ref([]),
    l2_tables: Ref([]),
    table_gen: Ref(1),
    l1_bytes: Ref(0),
    l2_bytes: Ref(0),
    snapshots: Ref([]),
    next_snap_id: Ref(0UL),
    pending: Ref([]),
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

/// A group of writes applied atomically: the memtable gets one contiguous
/// sequence range and the WAL one batch record, so recovery replays the
/// whole batch or none of it.
pub(all) struct WriteBatch {
  ops : Array[(Bytes, Option[Bytes])]
}

pub fn WriteBatch::new() -> WriteBatch {
  { ops: [] }
}

pub fn WriteBatch::put(self : WriteBatch, key : Bytes, value : Bytes) -> WriteBatch {
  self.ops.push((key, Some(value)))
  self
}

pub fn WriteBatch::delete(self : WriteBatch, key : Bytes) -> WriteBatch {
  self.ops.push((key, None))
  self
}

pub fn WriteBatch::is_empty(self : WriteBatch) -> Bool {
  self.ops.is_empty()
}

/// Applies every write in the batch at once. Writes within one batch win
/// over earlier ones by sequence number, like single writes do.
pub fn Db::write(self : Db, batch : WriteBatch) -> Unit raise DbError {
  if batch.is_empty() {
    return
  }
  let base = self.next_seq.val
  for i = 0; i < batch.ops.length(); i = i + 1 {
    let (key, value) = batch.ops[i]
    self.memtable.put(key, value, base + i.to_uint64())
  }
  self.wal.append_batch(batch.ops, base)
  self.next_seq.val = base + batch.ops.length().to_uint64()
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
  // L1/L2 tables are kept newest-first (descending S): a stale overlapping
  // table left by a crash is shadowed by the newer one checked first.
  for t in self.l1_tables.val {
    if t.reader.may_contain(key) {
      match t.reader.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  for t in self.l2_tables.val {
    if t.reader.may_contain(key) {
      match t.reader.get(key) {
        Some(v) => return Some(v)
        None => ()
      }
    }
  }
  None
}

/// Returns a merge iterator over all live entries, in ascending key order.
pub fn Db::scan(self : Db) -> MergeIterator {
  let streams : Array[Stream] = []
  streams.push(Stream::Mem(self.memtable.iter()))
  for r in self.l0_readers.val {
    streams.push(Stream::Sst(r.cursor()))
  }
  for t in self.l1_tables.val {
    streams.push(Stream::Sst(t.reader.cursor()))
  }
  for t in self.l2_tables.val {
    streams.push(Stream::Sst(t.reader.cursor()))
  }
  MergeIterator::new(streams)
}

/// Scans every live entry whose key starts with `prefix`, in ascending key
/// order. Stops early at the first key outside the prefix, so iterating a
/// small key range does not walk the whole store.
pub fn Db::scan_prefix(self : Db, prefix : Bytes) -> RangeIterator {
  RangeIterator::new_prefix(self.scan(), prefix)
}

/// Scans every live entry with start <= key < end, in ascending key order.
/// `end = None` means no upper bound. Stops early at the first key ≥ end.
pub fn Db::scan_range(self : Db, start : Bytes, end : Option[Bytes]) -> RangeIterator {
  RangeIterator::new(self.scan(), start, end)
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
  // 6. L1 compaction once enough L0 tables have piled up, then an L2
  //    compaction if L1 has grown past the size trigger and ratio.
  if self.l0_names.val.length() >= self.opts.l0_compaction_trigger {
    self.compact()
    self.maybe_compact_l2()
  }
}

/// L0 → L1: merges every L0 table plus the L1 tables whose ranges overlap
/// the L0 span, splitting the output into tables of at most
/// `opts.table_size_limit` bytes. No-op while L0 is empty (a repeated
/// compaction with no new writes does not touch any file).
///
/// This is a *non-bottom* merge: tombstones are retained (MergeIterator
/// `next_raw`) because L2 may still hold older versions of a deleted key —
/// dropping the tombstone here would resurrect them.
pub fn Db::compact(self : Db) -> Unit raise DbError {
  if self.l0_names.val.is_empty() {
    return
  }
  let streams : Array[Stream] = []
  let mut lo_min : Option[Bytes] = None
  let mut lo_max : Option[Bytes] = None
  for r in self.l0_readers.val {
    let fk = r.first_key()
    let lk = r.max_key()
    match lo_min {
      None => lo_min = Some(fk)
      Some(prev) => {
        if fk.lexical_compare(prev) < 0 {
          lo_min = Some(fk)
        }
      }
    }
    match lo_max {
      None => lo_max = Some(lk)
      Some(prev) => {
        if lk.lexical_compare(prev) > 0 {
          lo_max = Some(lk)
        }
      }
    }
    streams.push(Stream::Sst(r.cursor()))
  }
  let consumed_l1 : Array[Table] = []
  let kept_l1 : Array[Table] = []
  for t in self.l1_tables.val {
    if span_overlaps(t, lo_min.unwrap(), lo_max.unwrap()) {
      streams.push(Stream::Sst(t.reader.cursor()))
      consumed_l1.push(t)
    } else {
      kept_l1.push(t)
    }
  }
  let it = MergeIterator::new(streams)
  let pieces = self.merge_to_tables(it, "L1", false)
  // Inputs are released oldest-first: a crash mid-cleanup leaves the newest
  // copies on disk, and the reads (S-descending) find them first.
  for i = consumed_l1.length() - 1; i >= 0; i = i - 1 {
    self.release_file(consumed_l1[i].name)
  }
  for n in self.l0_names.val {
    self.release_file(n)
  }
  self.l0_names.val = []
  self.l0_readers.val = []
  let mut tables = kept_l1
  let mut l1_bytes = 0
  for t in kept_l1 {
    l1_bytes = l1_bytes + t.bytes
  }
  for t in pieces {
    tables = insert_table(tables, t)
    l1_bytes = l1_bytes + t.bytes
  }
  self.l1_tables.val = tables
  self.l1_bytes.val = l1_bytes
}

/// L1 → L2 (selective): picks the oldest L1 table and merges it with every
/// L1/L2 table whose range overlaps it — sweeping stale leftovers at the
/// same time. Tombstones are suppressed here: every older version of any
/// merged key is in the merge, so nothing is left for a dropped tombstone
/// to cover. The new tables land (and validate) before any input file is
/// removed. No-op while L1 is empty.
pub fn Db::compact_l2(self : Db) -> Unit raise DbError {
  let l1 = self.l1_tables.val
  if l1.is_empty() {
    return
  }
  // Oldest first: the last table in the newest-first (S-descending) order.
  let picked = l1[l1.length() - 1]
  let streams : Array[Stream] = []
  let consumed_l1 : Array[Table] = []
  let kept_l1 : Array[Table] = []
  for t in l1 {
    if span_overlaps(t, picked.min_key, picked.max_key) {
      streams.push(Stream::Sst(t.reader.cursor()))
      consumed_l1.push(t)
    } else {
      kept_l1.push(t)
    }
  }
  let consumed_l2 : Array[Table] = []
  let kept_l2 : Array[Table] = []
  for t in self.l2_tables.val {
    if span_overlaps(t, picked.min_key, picked.max_key) {
      streams.push(Stream::Sst(t.reader.cursor()))
      consumed_l2.push(t)
    } else {
      kept_l2.push(t)
    }
  }
  let it = MergeIterator::new(streams)
  let pieces = self.merge_to_tables(it, "L2", true)
  // L2 inputs first, then L1 inputs, oldest-first within each level: any
  // crash prefix keeps the tombstone-bearing L1 tables (the newest
  // versions) on disk, so a suppressed tombstone can never let an older
  // L2 copy resurrect a deleted key.
  for i = consumed_l2.length() - 1; i >= 0; i = i - 1 {
    self.release_file(consumed_l2[i].name)
  }
  for i = consumed_l1.length() - 1; i >= 0; i = i - 1 {
    self.release_file(consumed_l1[i].name)
  }
  let mut l1_bytes = 0
  for t in kept_l1 {
    l1_bytes = l1_bytes + t.bytes
  }
  self.l1_tables.val = kept_l1
  self.l1_bytes.val = l1_bytes
  let mut tables = kept_l2
  let mut l2_bytes = 0
  for t in kept_l2 {
    l2_bytes = l2_bytes + t.bytes
  }
  for t in pieces {
    tables = insert_table(tables, t)
    l2_bytes = l2_bytes + t.bytes
  }
  self.l2_tables.val = tables
  self.l2_bytes.val = l2_bytes
}

/// Runs L2 compactions one at a time while L1 has grown to
/// `l2_size_trigger` bytes and to at least 1/`l2_size_ratio` of L2 — the
/// size ratio keeps write amplification bounded: a large cold bottom table
/// is not rewritten every time a little fresh data piles up. Each round
/// consumes at least one L1 table, so the loop terminates.
fn Db::maybe_compact_l2(self : Db) -> Unit raise DbError {
  while !self.l1_tables.val.is_empty() {
    let l1 = self.l1_bytes.val
    let l2 = self.l2_bytes.val
    if l1 < self.opts.l2_size_trigger {
      return
    }
    if l2 > 0 && l1 * self.opts.l2_size_ratio < l2 {
      return
    }
    self.compact_l2()
  }
}

/// Merges `it` into fresh L<level>_<S>_<G> tables split at
/// `opts.table_size_limit`. `suppress` drops tombstones (bottom merges).
/// Every piece is written and validated before the caller removes inputs.
fn Db::merge_to_tables(
  self : Db,
  it : MergeIterator,
  level : String,
  suppress : Bool
) -> Array[Table] raise DbError {
  let tables : Array[Table] = []
  let mut builder = SstBuilder::new(block_size=self.opts.block_size)
  let mut piece_seq = 0UL
  let mut piece_first : Option[Bytes] = None
  let mut piece_last : Option[Bytes] = None
  let mut piece_entries = 0
  let limit = self.opts.table_size_limit
  while true {
    let e = if suppress {
      it.next()
    } else {
      it.next_raw()
    }
    match e {
      None => break
      Some(entry) => {
        // Seal the current piece before it outgrows the size limit.
        let est = entry.key.length() +
          (match entry.value {
            None => 0
            Some(v) => v.length()
          }) + 32
        if piece_entries > 0 && builder.approx_size() + est >= limit {
          let t = self.seal_piece(builder, level, piece_seq, piece_first, piece_last)
          tables.push(t)
          builder = SstBuilder::new(block_size=self.opts.block_size)
          piece_seq = 0UL
          piece_first = None
          piece_last = None
          piece_entries = 0
        }
        if entry.seq > piece_seq {
          piece_seq = entry.seq
        }
        match piece_first {
          None => piece_first = Some(entry.key)
          Some(_) => ()
        }
        piece_last = Some(entry.key)
        builder.add(entry)
        piece_entries = piece_entries + 1
      }
    }
  }
  match it.error() {
    Some(err) => raise err
    None => ()
  }
  if piece_entries > 0 {
    let t = self.seal_piece(builder, level, piece_seq, piece_first, piece_last)
    tables.push(t)
  }
  tables
}

/// Writes one finished piece under a fresh name and validates it.
fn Db::seal_piece(
  self : Db,
  builder : SstBuilder,
  level : String,
  seq : UInt64,
  first : Option[Bytes],
  last : Option[Bytes]
) -> Table raise DbError {
  let bytes = builder.finish()
  let gen = self.table_gen.val
  self.table_gen.val = gen + 1
  let name = "\{level}_\{seq}_\{gen}.sst"
  write(self.storage, name, bytes)
  let reader = parse(bytes)
  match (first, last) {
    (Some(fk), Some(lk)) => {
      name: name,
      reader: reader,
      seq: seq,
      min_key: fk,
      max_key: lk,
      bytes: bytes.length(),
    }
    _ => raise DbError::Corrupt("sst: empty compaction piece")
  }
}

/// Inserts `t` keeping the array ordered by descending `seq` (newest first).
fn insert_table(tables : Array[Table], t : Table) -> Array[Table] {
  let out : Array[Table] = []
  let mut done = false
  for u in tables {
    if !done && u.seq < t.seq {
      out.push(t)
      done = true
    }
    out.push(u)
  }
  if !done {
    out.push(t)
  }
  out
}

/// True when [a.min_key, a.max_key] intersects [b_min, b_max] (closed
/// intervals — a shared boundary key counts, so a table holding that key is
/// never missed).
fn span_overlaps(a : Table, b_min : Bytes, b_max : Bytes) -> Bool {
  a.min_key.lexical_compare(b_max) <= 0 && a.max_key.lexical_compare(b_min) >= 0
}

/// True when every key of table `t` provably lives in some table of
/// `candidates` with S >= t.seq — i.e. t was merged into them and can be
/// dropped at recovery (see the header comment). Two checks:
///   * one candidate whose range contains t's whole range;
///   * a key-space union walk over t's own keys: each key must fall inside
///     a candidate's range. Interval gaps between candidates are fine —
///     split outputs do not tile the byte space contiguously, but every key
///     of t went into one of the pieces (their key sets partition the merge
///     input). A candidate that contains key k was produced by a merge that
///     consumed t, so its version of k is at least as new as t's.
fn covered_by(t : Table, candidates : Array[Table]) -> Bool {
  for u in candidates {
    if u.seq >= t.seq &&
      u.min_key.lexical_compare(t.min_key) <= 0 &&
      u.max_key.lexical_compare(t.max_key) >= 0 {
      return true
    }
  }
  let cands : Array[Table] = []
  for u in candidates {
    if u.seq >= t.seq &&
      u.min_key.lexical_compare(t.max_key) <= 0 &&
      u.max_key.lexical_compare(t.min_key) >= 0 {
      cands.push(u)
    }
  }
  if cands.is_empty() {
    return false
  }
  // Insertion sort by min_key. Candidate ranges may overlap after a crash
  // (keep-all residue); the walk below stays sound either way.
  let mut sorted : Array[Table] = []
  for u in cands {
    let mut at = 0
    while at < sorted.length() && sorted[at].min_key.lexical_compare(u.min_key) < 0 {
      at = at + 1
    }
    let next : Array[Table] = []
    for i = 0; i < at; i = i + 1 {
      next.push(sorted[i])
    }
    next.push(u)
    for i = at; i < sorted.length(); i = i + 1 {
      next.push(sorted[i])
    }
    sorted = next
  }
  let c = t.reader.cursor()
  let mut ci = 0
  while true {
    match c.peek() {
      None => break
      Some(e) => {
        while ci < sorted.length() &&
          sorted[ci].max_key.lexical_compare(e.key) < 0 {
          ci = ci + 1
        }
        if ci >= sorted.length() ||
          sorted[ci].min_key.lexical_compare(e.key) > 0 {
          return false
        }
        c.advance()
      }
    }
  }
  match c.error() {
    Some(_) => false
    None => true
  }
}

/// True if any live snapshot still pins `name`.
fn Db::file_held(self : Db, name : String) -> Bool {
  for snap in self.snapshots.val {
    if snap.closed.val {
      continue
    }
    for n in snap.l0_names {
      if n == name {
        return true
      }
    }
    for n in snap.l1_names {
      if n == name {
        return true
      }
    }
    for n in snap.l2_names {
      if n == name {
        return true
      }
    }
  }
  false
}

/// Removes a table file compaction no longer needs, unless a live snapshot
/// still reads it — then it is deferred to the pending list and physically
/// deleted when the last holder releases.
fn Db::release_file(self : Db, name : String) -> Unit raise DbError {
  if self.file_held(name) {
    self.pending.val.push(name)
  } else {
    remove(self.storage, name)
  }
}

/// Unregisters a closed snapshot and sweeps the pending list: files no
/// snapshot holds any more are deleted now.
pub fn Db::release_snapshot(self : Db, id : UInt64) -> Unit raise DbError {
  let kept : Array[Snapshot] = []
  for snap in self.snapshots.val {
    if snap.id != id {
      kept.push(snap)
    }
  }
  self.snapshots.val = kept
  let kept_pending : Array[String] = []
  for p in self.pending.val {
    if self.file_held(p) {
      kept_pending.push(p)
    } else {
      remove(self.storage, p)
    }
  }
  self.pending.val = kept_pending
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
    l1_files: self.l1_tables.val.length(),
    l1_bytes: self.l1_bytes.val,
    l2_files: self.l2_tables.val.length(),
    l2_bytes: self.l2_bytes.val,
  }
}

/// One parsed L<ℓ>_<S>.sst / L<ℓ>_<S>_<G>.sst file name.
priv struct ParsedName {
  seq : UInt64
  gen : UInt64
  /// Legacy names (no G part) were produced by the old single-table design,
  /// whose full merges admit the legacy recovery rules below.
  legacy : Bool
}

/// Parses `L1_<S>.sst` (legacy, gen 0) or `L1_<S>_<G>.sst` (current).
fn parse_table_name(name : String) -> Option[ParsedName] {
  if !(name.has_prefix("L1_") || name.has_prefix("L2_")) {
    return None
  }
  let n = name.length()
  if n < 8 || !name.has_suffix(".sst") {
    return None
  }
  let mut sep = 3
  while sep < n - 4 && name[sep] != '_' {
    sep = sep + 1
  }
  if sep == 3 {
    return None
  }
  match parse_decimal(name, 3, sep - 3) {
    None => return None
    Some(s) => {
      let gen = if sep == n - 4 {
        0UL
      } else {
        match parse_decimal(name, sep + 1, n - 4 - sep - 1) {
          None => return None
          Some(g) => g
        }
      }
      Some({ seq: s, gen: gen, legacy: sep == n - 4 })
    }
  }
}

/// Reads and parses one table file; a missing or unparsable file is removed.
fn Db::load_table(self : Db, name : String, seq : UInt64) -> Option[Table] raise DbError {
  match read(self.storage, name) {
    None => None
    Some(bytes) => {
      let parsed = try {
        Some(parse(bytes))
      } catch {
        _ => None
      }
      match parsed {
        None => {
          remove(self.storage, name)
          None
        }
        Some(r) => {
          let fk = r.first_key()
          let lk = r.max_key()
          Some({
            name: name,
            reader: r,
            seq: seq,
            min_key: fk,
            max_key: lk,
            bytes: bytes.length(),
          })
        }
      }
    }
  }
}

/// Restores Db state from storage. See the header comment for the rules.
fn Db::recover(self : Db) -> Unit raise DbError {
  let l0_names = list(self.storage, "L0_")
  let l1_names = list(self.storage, "L1_")
  let l2_names = list(self.storage, "L2_")
  let mut max_gen = 0
  let mut max_seq = 0UL

  // L2: load every valid table, then drop those provably merged into newer
  // ones (the coverage test needs the full set, so it runs after loading).
  let all_l2 : Array[(Table, Bool)] = []
  for name in l2_names {
    match parse_table_name(name) {
      None => remove(self.storage, name)
      Some(p) => {
        if !p.legacy && p.gen.to_int() > max_gen {
          max_gen = p.gen.to_int()
        }
        match self.load_table(name, p.seq) {
          None => ()
          Some(t) => all_l2.push((t, p.legacy))
        }
      }
    }
  }
  let mut kept_l2 : Array[Table] = []
  let mut legacy_l2_s = 0UL
  for pair in all_l2 {
    let (t, legacy) = pair
    let others : Array[Table] = []
    for (u, _) in all_l2 {
      if u.name != t.name {
        others.push(u)
      }
    }
    if covered_by(t, others) {
      remove(self.storage, t.name)
    } else {
      if t.seq > max_seq {
        max_seq = t.seq
      }
      if legacy && t.seq > legacy_l2_s {
        legacy_l2_s = t.seq
      }
      kept_l2 = insert_table(kept_l2, t)
    }
  }
  self.l2_tables.val = kept_l2
  let mut l2_bytes = 0
  for t in kept_l2 {
    l2_bytes = l2_bytes + t.bytes
  }
  self.l2_bytes.val = l2_bytes

  // L1 keep-all: every valid table survives. Only legacy L1 tables fully
  // merged into a surviving legacy L2 (S >=) can be dropped.
  let mut kept_l1 : Array[Table] = []
  for name in l1_names {
    match parse_table_name(name) {
      None => remove(self.storage, name)
      Some(p) => {
        if !p.legacy && p.gen.to_int() > max_gen {
          max_gen = p.gen.to_int()
        }
        match self.load_table(name, p.seq) {
          None => ()
          Some(t) => {
            if p.legacy && legacy_l2_s > 0UL && legacy_l2_s >= t.seq {
              remove(self.storage, t.name)
            } else {
              if t.seq > max_seq {
                max_seq = t.seq
              }
              kept_l1 = insert_table(kept_l1, t)
            }
          }
        }
      }
    }
  }
  self.l1_tables.val = kept_l1
  let mut l1_bytes = 0
  for t in kept_l1 {
    l1_bytes = l1_bytes + t.bytes
  }
  self.l1_bytes.val = l1_bytes

  // L0: drop tables whose every key is provably covered by L1 tables with
  // S >= the table's max seq (compact merges every L0 table), or by a
  // surviving legacy L2 (the old full merge subsumed everything).
  let mut max_l0_num = -1
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
                let l0_table : Table = {
                  name: name,
                  reader: r,
                  seq: m,
                  min_key: r.first_key(),
                  max_key: r.max_key(),
                  bytes: bytes.length(),
                }
                let covered = covered_by(l0_table, kept_l1) ||
                  (legacy_l2_s > 0UL && m <= legacy_l2_s)
                if covered {
                  remove(self.storage, name)
                } else {
                  if m > max_seq {
                    max_seq = m
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
  self.table_gen.val = max_gen + 1
  // WAL: replay every valid record. The WAL on disk is at most the last
  // sealed batch (or its lost-write remainder); later records within it
  // supersede earlier ones, so the memtable ends up with the newest version
  // of every key — no record is skipped (a global coverage watermark is not
  // sound with selective merges).
  match read(self.storage, "WAL") {
    None => ()
    Some(bytes) => {
      let (records, valid) = parse_wal(bytes)
      self.wal = Wal::from_bytes(bytes[0:valid])
      if valid < bytes.length() {
        write(self.storage, "WAL", bytes[0:valid].to_owned())
      }
      for r in records {
        self.memtable.put(r.key, r.value, r.seq)
      }
    }
  }
  // The next sequence must clear everything recovered: every surviving
  // table's S plus anything replayed from the WAL.
  let mem_seq = self.memtable.max_seq()
  let top = if mem_seq > max_seq { mem_seq } else { max_seq }
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
