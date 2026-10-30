// stats.mbt
//
// A point-in-time snapshot of Db state, for tests, debugging and demos.

pub(all) struct Stats {
  /// Estimated byte size of the current memtable.
  memtable_bytes : Int
  /// Bytes currently buffered in the WAL (unflushed records).
  wal_bytes : Int
  /// Number of L0 tables on disk.
  l0_files : Int
  /// Number of L1 tables on disk (pairwise disjoint key ranges).
  l1_files : Int
  /// Total byte size of the L1 tables.
  l1_bytes : Int
  /// Number of L2 tables on disk (pairwise disjoint key ranges).
  l2_files : Int
  /// Total byte size of the L2 tables.
  l2_bytes : Int
}
