// options.mbt
//
// Tuning knobs for a Db. All sizes are in bytes.

pub(all) struct Options {
  /// Memtable byte budget; exceeding it triggers an automatic flush.
  memtable_limit : Int
  /// SSTable block size passed to SstBuilder.
  block_size : Int
  /// Flush ends with a compaction once this many L0 tables have piled up.
  l0_compaction_trigger : Int
}

pub fn Options::default() -> Options {
  {
    memtable_limit: 4_194_304,
    block_size: 4096,
    l0_compaction_trigger: 4,
  }
}

pub fn Options::with_memtable_limit(self : Options, n : Int) -> Options {
  {
    memtable_limit: n,
    block_size: self.block_size,
    l0_compaction_trigger: self.l0_compaction_trigger,
  }
}

pub fn Options::with_compaction_trigger(self : Options, n : Int) -> Options {
  {
    memtable_limit: self.memtable_limit,
    block_size: self.block_size,
    l0_compaction_trigger: n,
  }
}
