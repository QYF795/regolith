// main.mbt
//
// A small standalone demo of the library API: opens a database under
// demo-data/ (git-ignored), walks the whole delivered surface — point
// reads, batch writes, prefix/range scans, snapshot, flush, L1/L2
// compaction — and prints the results. Run with:
//
//   moon run --target js demo

fn err_text(e : @QYF795/regolith.DbError) -> String {
  match e {
    @QYF795/regolith.DbError::Io(m) => m
    @QYF795/regolith.DbError::Corrupt(m) => m
    @QYF795/regolith.DbError::Fault(m) => m
  }
}

/// Renders an Option[Option[Bytes]] read result for the demo output.
fn show(r : Option[Option[Bytes]]) -> String {
  match r {
    None => "(not found)"
    Some(None) => "(deleted)"
    Some(Some(v)) => view(v)
  }
}

/// UTF-8 when valid, `0x…` hex otherwise.
fn view(bytes : Bytes) -> String {
  try {
    @utf8.decode(bytes)
  } catch {
    _ => {
      let mut out = "0x"
      for i = 0; i < bytes.length(); i = i + 1 {
        let b = bytes[i].to_int() & 0xFF
        out = out + (b.to_string())
      }
      out
    }
  }
}

/// Renders a full merge iterator as `  key = value` lines.
fn render(it : @QYF795/regolith.MergeIterator) -> String {
  let mut out = ""
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        None => ()
        Some(v) => out = out + "  " + view(e.key) + " = " + view(v) + "\n"
      }
    }
  }
  match it.error() {
    Some(err) => out = out + "  scan error: " + err_text(err) + "\n"
    None => ()
  }
  out
}

/// Renders a range iterator the same way (scan_prefix/scan_range).
fn render_range(it : @QYF795/regolith.RangeIterator) -> String {
  let mut out = ""
  while true {
    match it.next() {
      None => break
      Some(e) => match e.value {
        None => ()
        Some(v) => out = out + "  " + view(e.key) + " = " + view(v) + "\n"
      }
    }
  }
  match it.error() {
    Some(err) => out = out + "  scan error: " + err_text(err) + "\n"
    None => ()
  }
  out
}

fn stats_line(db : @QYF795/regolith.Db) -> String {
  let s = db.stats()
  "memtable=\{s.memtable_bytes}B wal=\{s.wal_bytes}B l0=\{s.l0_files} l1=\{s.l1_files} l2=\{s.l2_files}"
}

fn main {
  println("regolith demo — 月壤 LSM KV store")
  println("==================================\n")
  try {
    let db = @QYF795/regolith.Db::open("demo-data")
    println("[put] hello=regolith, moon=bit, lsm=wal+memtable+sstable")
    db.put(b"hello", b"regolith")
    db.put(b"moon", b"bit")
    db.put(b"lsm", b"wal + memtable + sstable")
    println("[get] hello -> \{show(db.get(b"hello"))}")
    println("[get] missing -> \{show(db.get(b"missing"))}\n")

    println("[batch] one atomic commit: user:1=alice, user:2=bob, meta=v1")
    db.write(
      @QYF795/regolith.WriteBatch::new()
        .put(b"user:1", b"alice")
        .put(b"user:2", b"bob")
        .put(b"meta", b"v1"),
    )
    println("[scan_prefix user:]")
    println(render_range(db.scan_prefix(b"user:")))
    println("[scan_range meta, user:1):")
    println(render_range(db.scan_range(b"meta", Some(b"user:1"))))

    println("[scan] all live entries:")
    println(render(db.scan()))

    println("[snapshot] frozen view before deleting moon")
    let snap = db.snapshot()
    println("[del] moon")
    db.delete(b"moon")
    println("[get] moon -> \{show(db.get(b"moon"))}")
    // The snapshot still sees the state as of snapshot time.
    println("[snapshot get] moon -> \{show(snap.get(b"moon"))}\n")
    println("[snapshot scan] all entries as of snapshot time:")
    println(render(snap.scan()))
    snap.close()
    println("[flush]")
    db.flush()
    println("[stats] \{stats_line(db)}")

    println("\n[compact] merge everything into the bottom level (L2)")
    db.compact()
    db.compact_l2()
    println("[stats] \{stats_line(db)}")
    println("[get] hello -> \{show(db.get(b"hello"))}")
    println("[get] moon -> \{show(db.get(b"moon"))}")
    println("[scan] after compaction:")
    println(render(db.scan()))

    println("[close]")
    db.close()
    println("done — data persisted under demo-data/")
  } catch {
    e => println("demo failed: \{err_text(e)}")
  }
}
