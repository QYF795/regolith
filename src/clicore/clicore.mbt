// clicore.mbt
//
// The command engine behind the `regolith` CLI: parses a command-line token
// array (program name excluded) and runs it against a @regolith.Db, returning the
// printable result. Pure logic — no argv or stdin access — so every command
// is testable against an in-memory database.

const HEX_DIGITS : String = "0123456789abcdef"

fn hex_char(n : Int) -> String {
  HEX_DIGITS[n:n + 1].to_owned()
}

/// Renders bytes for the terminal: UTF-8 when valid, `0x…` hex otherwise.
fn show_bytes(bytes : Bytes) -> String {
  try {
    @utf8.decode(bytes)
  } catch {
    _ => {
      let mut out = "0x"
      for i = 0; i < bytes.length(); i = i + 1 {
        let b = bytes[i].to_int() & 0xFF
        out = out + hex_char(b >> 4) + hex_char(b & 0xF)
      }
      out
    }
  }
}

/// Runs one command (argv without the program name) and returns its output.
/// Usage errors come back as text starting with "error:"; storage failures
/// are raised.
pub fn run(db : @regolith.Db, argv : Array[String]) -> String raise @regolith.DbError {
  if argv.length() == 0 {
    return "error: no command (try \"help\")"
  }
  match argv[0] {
    "set" => {
      if argv.length() != 3 {
        "error: usage: set <key> <value>"
      } else {
        db.put(@utf8.encode(argv[1]), @utf8.encode(argv[2]))
        // "ok" means durable: the CLI process exits right after printing it.
        db.flush()
        "ok"
      }
    }
    "get" => {
      if argv.length() != 2 {
        "error: usage: get <key>"
      } else {
        match db.get(@utf8.encode(argv[1])) {
          None => "(not found)"
          Some(None) => "(deleted)"
          Some(Some(v)) => show_bytes(v)
        }
      }
    }
    "del" => {
      if argv.length() != 2 {
        "error: usage: del <key>"
      } else {
        db.delete(@utf8.encode(argv[1]))
        // Same as set: make the delete durable before the process exits.
        db.flush()
        "ok"
      }
    }
    "scan" => {
      let mut out = ""
      let it = db.scan()
      while true {
        match it.next() {
          None => break
          Some(e) => match e.value {
            None => ()
            Some(v) => out = out + show_bytes(e.key) + "=" + show_bytes(v) + "\n"
          }
        }
      }
      match it.error() {
        Some(err) => raise err
        None => ()
      }
      out
    }
    "scan_prefix" => {
      if argv.length() != 2 {
        "error: usage: scan_prefix <prefix>"
      } else {
        let mut out = ""
        let it = db.scan_prefix(@utf8.encode(argv[1]))
        while true {
          match it.next() {
            None => break
            Some(e) => match e.value {
              None => ()
              Some(v) => out = out + show_bytes(e.key) + "=" + show_bytes(v) + "\n"
            }
          }
        }
        match it.error() {
          Some(err) => raise err
          None => ()
        }
        out
      }
    }
    "scan_range" => {
      if argv.length() != 3 {
        "error: usage: scan_range <start> <end>"
      } else {
        // An empty end means "no upper bound": scan to the last key.
        let end = if argv[2] == "" {
          None
        } else {
          Some(@utf8.encode(argv[2]))
        }
        let mut out = ""
        let it = db.scan_range(@utf8.encode(argv[1]), end)
        while true {
          match it.next() {
            None => break
            Some(e) => match e.value {
              None => ()
              Some(v) => out = out + show_bytes(e.key) + "=" + show_bytes(v) + "\n"
            }
          }
        }
        match it.error() {
          Some(err) => raise err
          None => ()
        }
        out
      }
    }
    "flush" => {
      db.flush()
      "ok"
    }
    "compact" => {
      db.compact()
      db.compact_l2()
      "ok"
    }
    "stats" => {
      let s = db.stats()
      "memtable: \{s.memtable_bytes} bytes\nwal: \{s.wal_bytes} bytes\nl0: \{s.l0_files} tables\nl1: \{s.l1_files} tables\nl2: \{s.l2_files} tables"
    }
    "help" =>
      "commands:\n  set <key> <value>  write a key\n  get <key>          read a key\n  del <key>          delete a key\n  scan               list all live entries\n  scan_prefix <p>    list entries whose key starts with p\n  scan_range <a> <b> list entries with a <= key < b (empty b = unbounded)\n  flush              flush the memtable to L0\n  compact            merge everything into L2\n  stats              storage statistics\n  help               this help"
    _ => "error: unknown command \{argv[0]} (try \"help\")"
  }
}
