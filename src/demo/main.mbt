// main.mbt
//
// A small standalone demo of the library API: opens a database under
// demo-data/ (git-ignored), writes a few keys, reads them back, scans,
// deletes, flushes and prints statistics. Run with:
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
    println("[scan] all live entries:")
    let it = db.scan()
    while true {
      match it.next() {
        None => break
        Some(e) => match e.value {
          None => ()
          Some(v) => println("  \{view(e.key)} = \{view(v)}")
        }
      }
    }
    match it.error() {
      Some(err) => println("scan error: \{err_text(err)}")
      None => ()
    }
    println("\n[del] moon")
    db.delete(b"moon")
    println("[get] moon -> \{show(db.get(b"moon"))}\n")
    println("[flush]")
    db.flush()
    let s = db.stats()
    println(
      "[stats] memtable=\{s.memtable_bytes}B wal=\{s.wal_bytes}B l0=\{s.l0_files} l1=\{s.l1_files} l2=\{s.l2_files}",
    )
    println("\n[close]")
    db.close()
    println("done — data persisted under demo-data/")
  } catch {
    e => println("demo failed: \{err_text(e)}")
  }
}
