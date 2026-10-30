// options.mbt
//
// Tuning knobs for a Db. All sizes are in bytes.

pub(all) struct Options {
  /// Memtable byte budget; exceeding it triggers an automatic flush.
  memtable_limit : Int
  /// SSTable block size passed to SstBuilder.
  block_size : Int
  /// Flush ends with an L1 compaction once this many L0 tables have piled up.
  l0_compaction_trigger : Int
  /// Minimum L1 bytes before an L1 → L2 compaction is considered.
  l2_size_trigger : Int
  /// L2 compaction also requires l1_bytes * ratio >= l2_bytes: the bottom
  /// table is only rewritten once L1 grows to a meaningful fraction of it,
  /// which keeps write amplification bounded as the store grows.
  l2_size_ratio : Int
  /// Target byte size of one L1/L2 compaction output table. A merge larger
  /// than this is split into several tables with disjoint key ranges.
  table_size_limit : Int
}

pub fn Options::default() -> Options {
  {
    memtable_limit: 4_194_304,
    block_size: 4096,
    l0_compaction_trigger: 4,
    l2_size_trigger: 4_194_304,
    l2_size_ratio: 4,
    table_size_limit: 2_097_152,
  }
}

pub fn Options::with_memtable_limit(self : Options, n : Int) -> Options {
  {
    memtable_limit: n,
    block_size: self.block_size,
    l0_compaction_trigger: self.l0_compaction_trigger,
    l2_size_trigger: self.l2_size_trigger,
    l2_size_ratio: self.l2_size_ratio,
    table_size_limit: self.table_size_limit,
  }
}

pub fn Options::with_compaction_trigger(self : Options, n : Int) -> Options {
  {
    memtable_limit: self.memtable_limit,
    block_size: self.block_size,
    l0_compaction_trigger: n,
    l2_size_trigger: self.l2_size_trigger,
    l2_size_ratio: self.l2_size_ratio,
    table_size_limit: self.table_size_limit,
  }
}

/// Sets the minimum L1 byte size before L2 compaction is considered.
pub fn Options::with_l2_size_trigger(self : Options, n : Int) -> Options {
  {
    memtable_limit: self.memtable_limit,
    block_size: self.block_size,
    l0_compaction_trigger: self.l0_compaction_trigger,
    l2_size_trigger: n,
    l2_size_ratio: self.l2_size_ratio,
    table_size_limit: self.table_size_limit,
  }
}

/// Sets the L1/L2 size ratio that gates L2 compaction (see `l2_size_ratio`).
pub fn Options::with_l2_size_ratio(self : Options, n : Int) -> Options {
  {
    memtable_limit: self.memtable_limit,
    block_size: self.block_size,
    l0_compaction_trigger: self.l0_compaction_trigger,
    l2_size_trigger: self.l2_size_trigger,
    l2_size_ratio: n,
    table_size_limit: self.table_size_limit,
  }
}

/// Sets the target size of one compaction output table (see
/// `table_size_limit`).
pub fn Options::with_table_size_limit(self : Options, n : Int) -> Options {
  {
    memtable_limit: self.memtable_limit,
    block_size: self.block_size,
    l0_compaction_trigger: self.l0_compaction_trigger,
    l2_size_trigger: self.l2_size_trigger,
    l2_size_ratio: self.l2_size_ratio,
    table_size_limit: n,
  }
}
