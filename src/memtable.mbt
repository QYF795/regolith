// memtable.mbt
//
// The in-memory table: a skip list keyed by Bytes with put/get/ordered
// iteration. Deletes are tombstones (`value = None`), so `get` returns
// `Some(None)` for a deleted key and `None` for an absent one.
//
// Tower heights come from a deterministic xorshift64 stream so that the
// shape of the table (and therefore iteration order and any height-dependent
// behaviour) is reproducible across runs and backends.

const MAX_LEVEL : Int = 12

// Fixed xorshift64 seed: the golden-ratio constant, a classic stream seed.
const SKIP_SEED : UInt64 = 0x9E3779B97F4A7C15UL

struct Node {
  key : Bytes
  mut value : Option[Bytes]
  mut seq : UInt64
  nexts : Array[Node?]
}

pub(all) struct MemTable {
  head : Node
  rng : Ref[UInt64]
  size_bytes : Ref[Int]
  max_seq : Ref[UInt64]
}

/// A position inside a memtable, used by the merge iterator.
pub(all) struct MemIter {
  mut cur : Node?
}

pub fn MemTable::new() -> MemTable {
  let nexts : Array[Node?] = []
  for _i = 0; _i < MAX_LEVEL; _i = _i + 1 {
    nexts.push(None)
  }
  {
    head: { key: b"", value: None, seq: 0UL, nexts },
    rng: Ref(SKIP_SEED),
    size_bytes: Ref(0),
    max_seq: Ref(0UL),
  }
}

fn MemTable::roll_levels(self : MemTable) -> Int {
  let mut x = self.rng.val
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  self.rng.val = x
  let mut levels = 1
  let mut bits = x
  while (bits & 1UL) == 1UL && levels < MAX_LEVEL {
    levels += 1
    bits = bits >> 1
  }
  levels
}

fn MemTable::size_of(key : Bytes, value : Option[Bytes]) -> Int {
  let vlen = match value {
    Some(v) => v.length()
    None => 0
  }
  key.length() + vlen + 24
}

pub fn MemTable::put(self : MemTable, key : Bytes, value : Option[Bytes], seq : UInt64) -> Unit {
  let levels = self.roll_levels()
  // Search for the key first. A later put of an existing key replaces the
  // node in place and links nothing, so no second node for the same key can
  // ever enter the list (a linked duplicate whose level-0 pointer is None
  // would corrupt later walks, which descend through it and then stop).
  let mut cur = self.head
  for lvl = MAX_LEVEL - 1; lvl >= 0; lvl = lvl - 1 {
    while true {
      match cur.nexts[lvl] {
        None => break
        Some(next) => {
          if next.key.compare(key) < 0 {
            cur = next
          } else {
            break
          }
        }
      }
    }
  }
  match cur.nexts[0] {
    Some(n) => {
      if n.key == key {
        let old = MemTable::size_of(n.key, n.value)
        n.value = value
        n.seq = seq
        self.size_bytes.val = self.size_bytes.val - old + MemTable::size_of(key, value)
        if seq > self.max_seq.val {
          self.max_seq.val = seq
        }
        return
      }
    }
    None => ()
  }
  // New key: build the node and link it into every level up to its height.
  let nexts : Array[Node?] = []
  for _i = 0; _i < levels; _i = _i + 1 {
    nexts.push(None)
  }
  let node = { key, value, seq, nexts }
  let mut walk = self.head
  for lvl = MAX_LEVEL - 1; lvl >= 0; lvl = lvl - 1 {
    while true {
      match walk.nexts[lvl] {
        None => break
        Some(next) => {
          if next.key.compare(key) < 0 {
            walk = next
          } else {
            break
          }
        }
      }
    }
    if lvl < levels {
      node.nexts[lvl] = walk.nexts[lvl]
      walk.nexts[lvl] = Some(node)
    }
  }
  self.size_bytes.val = self.size_bytes.val + MemTable::size_of(key, value)
  if seq > self.max_seq.val {
    self.max_seq.val = seq
  }
}

/// `None` = absent, `Some(None)` = tombstone, `Some(Some(v))` = live value.
pub fn MemTable::get(self : MemTable, key : Bytes) -> Option[Option[Bytes]] {
  let mut cur = self.head
  for lvl = MAX_LEVEL - 1; lvl >= 0; lvl = lvl - 1 {
    while true {
      match cur.nexts[lvl] {
        None => break
        Some(next) => {
          if next.key.compare(key) < 0 {
            cur = next
          } else {
            break
          }
        }
      }
    }
  }
  match cur.nexts[0] {
    Some(n) => {
      if n.key == key {
        Some(n.value)
      } else {
        None
      }
    }
    None => None
  }
}

pub fn MemTable::iter(self : MemTable) -> MemIter {
  { cur: self.head.nexts[0] }
}

pub fn MemTable::is_empty(self : MemTable) -> Bool {
  self.head.nexts[0] is None
}

pub fn MemTable::size_bytes(self : MemTable) -> Int {
  self.size_bytes.val
}

pub fn MemTable::max_seq(self : MemTable) -> UInt64 {
  self.max_seq.val
}

pub fn MemIter::peek(self : MemIter) -> Option[Entry] {
  match self.cur {
    None => None
    Some(n) => Some({ key: n.key, seq: n.seq, value: n.value })
  }
}

pub fn MemIter::advance(self : MemIter) -> Unit {
  match self.cur {
    None => ()
    Some(n) => self.cur = n.nexts[0]
  }
}

pub fn MemIter::error(_self : MemIter) -> Option[DbError] {
  None
}
