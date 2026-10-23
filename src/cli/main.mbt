// main.mbt
//
// The `regolith` CLI: subcommand-style argument parsing via core/argparse,
// with the actual command logic in clicore. Storage lives under
// regolith-data/ (git-ignored). Run with:
//
//   moon run --target js cli -- set hello regolith
//   moon run cli -- get hello        (native backend, needs a C compiler)

fn err_text(e : @regolith.DbError) -> String {
  match e {
    @regolith.DbError::Io(m) => m
    @regolith.DbError::Corrupt(m) => m
    @regolith.DbError::Fault(m) => m
  }
}

fn main {
  let cmd = @argparse.Command(
    "regolith",
    about="月壤 CLI — embedded LSM-tree KV store",
    version="0.1.0",
    subcommands=[
      @argparse.Command(
        "set",
        about="write key=value",
        positionals=[
          @argparse.PositionArg("key", num_args=@argparse.ValueRange::single()),
          @argparse.PositionArg("value", num_args=@argparse.ValueRange::single()),
        ],
      ),
      @argparse.Command(
        "get",
        about="read a key",
        positionals=[@argparse.PositionArg("key", num_args=@argparse.ValueRange::single())],
      ),
      @argparse.Command(
        "del",
        about="delete a key",
        positionals=[@argparse.PositionArg("key", num_args=@argparse.ValueRange::single())],
      ),
      @argparse.Command("scan", about="list all live entries"),
      @argparse.Command(
        "scan_prefix",
        about="list entries whose key starts with the prefix",
        positionals=[@argparse.PositionArg("prefix", num_args=@argparse.ValueRange::single())],
      ),
      @argparse.Command("flush", about="flush the memtable to L0"),
      @argparse.Command("compact", about="merge everything into L1"),
      @argparse.Command("stats", about="storage statistics"),
    ],
    subcommand_required=true,
  )
  // Parse failures already carry display-ready text with full help.
  let matches = try {
    cmd.parse()
  } catch {
    e => {
      println(e.to_string())
      return
    }
  }
  // Flatten the parsed subcommand back into a token array for clicore:
  // ["set", key, value] / ["get", key] / ["scan_prefix", prefix] / ...
  let argv : Array[String] = match matches.subcommand {
    Some((name, m)) => {
      let a : Array[String] = [name]
      for p in ["key", "value", "prefix"] {
        match m.values.get(p) {
          Some(vs) => {
            for v in vs {
              a.push(v)
            }
          }
          None => ()
        }
      }
      a
    }
    None => return // unreachable: subcommand_required
  }
  let db = try {
    @regolith.Db::open("regolith-data")
  } catch {
    e => {
      println("error: \{err_text(e)}")
      return
    }
  }
  let out = try {
    @clicore.run(db, argv)
  } catch {
    e => {
      println("error: \{err_text(e)}")
      return
    }
  }
  println(out)
}
