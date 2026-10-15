// storage.mbt
//
// The storage abstraction. MoonBit traits cannot be used as types, so the
// engine talks to a closed enum of storage implementations through the
// dispatch helpers below.
//
//   Memory     — an in-process map of file name to bytes (tests, embedders)
//   File       — a real directory via moonbitlang/x/fs (whole-file IO;
//                durability therefore comes from the WAL group commit)
//   Failpoint  — wraps a Memory storage and injects deterministic faults for
//                the crash-consistency suite (docs/acceptance.md §8)
//
// File names are relative paths inside the storage (e.g. "WAL",
// "L0_000042.sst"); File turns them into dir + "/" + name.

pub(all) enum Storage {
  Memory(MemoryStorage)
  File(FileStorage)
  Failpoint(FailpointStorage)
}

pub(all) struct MemoryStorage {
  files : @hashmap.HashMap[String, Bytes]
}

pub fn MemoryStorage::new() -> MemoryStorage {
  { files: @hashmap.HashMap([], capacity=16) }
}

pub(all) struct FileStorage {
  dir : String
}

pub fn FileStorage::new(dir : String) -> FileStorage {
  { dir, }
}

/// Fault kinds injectable through a FailpointStorage. `LostWrite` models a
/// write that reported success but never reached the medium (a lost fsync);
/// it only ever fires on WAL writes, because losing a table write silently
/// would be indistinguishable from corruption of the whole file.
pub(all) enum FaultKind {
  FailRead
  TornWrite
  LostWrite
} derive(Eq, @debug.Debug)

pub extend FaultKind with Eq::{not_equal, equal}
pub extend FaultKind with @debug.Debug::{to_repr}

pub(all) struct FailpointStorage {
  inner : MemoryStorage
  armed_kind : Ref[Option[FaultKind]]
  armed_name : Ref[Option[String]]
  fired : Ref[Bool]
}

pub fn FailpointStorage::new() -> FailpointStorage {
  {
    inner: MemoryStorage::new(),
    armed_kind: Ref(None),
    armed_name: Ref(None),
    fired: Ref(false),
  }
}

/// Arms a one-shot fault on the next matching operation, any file.
pub fn FailpointStorage::arm(self : FailpointStorage, kind : FaultKind) -> Unit {
  self.armed_kind.val = Some(kind)
  self.armed_name.val = None
  self.fired.val = false
}

/// Arms a one-shot fault that only fires for files whose name starts with
/// `name_prefix` (e.g. "WAL", "L0_", "L1_"). Other operations pass through.
pub fn FailpointStorage::arm_on(
  self : FailpointStorage,
  kind : FaultKind,
  name_prefix : String
) -> Unit {
  self.armed_kind.val = Some(kind)
  self.armed_name.val = Some(name_prefix)
  self.fired.val = false
}

pub fn FailpointStorage::disarm(self : FailpointStorage) -> Unit {
  self.armed_kind.val = None
}

/// True while an armed fault has not fired yet.
pub fn FailpointStorage::armed(self : FailpointStorage) -> Bool {
  self.armed_kind.val is Some(_) && !self.fired.val
}

fn FailpointStorage::match_name(self : FailpointStorage, name : String) -> Bool {
  match self.armed_name.val {
    None => true
    Some(prefix) => name.has_prefix(prefix)
  }
}

fn io_failure(what : String, path : String, msg : String) -> DbError {
  DbError::Io("\{what} \{path}: \{msg}")
}

/// Reads a whole file; `None` means the file does not exist.
pub fn read(storage : Storage, name : String) -> Option[Bytes] raise DbError {
  match storage {
    Memory(m) => m.files.get(name)
    File(f) => {
      let path = "\{f.dir}/\{name}"
      if !@fs.path_exists(path) {
        None
      } else {
        let content =
          @fs.read_file_to_bytes(path) catch {
            @fs.IOError(msg) => raise io_failure("read", path, msg)
          }
        Some(content)
      }
    }
    Failpoint(fp) => {
      if fp.armed() && fp.match_name(name) && fp.armed_kind.val == Some(FaultKind::FailRead) {
        fp.fired.val = true
        raise DbError::Fault("injected read failure: \{name}")
      }
      read(Storage::Memory(fp.inner), name)
    }
  }
}

/// Writes a whole file, creating or replacing it.
pub fn write(storage : Storage, name : String, data : Bytes) -> Unit raise DbError {
  match storage {
    Memory(m) => m.files.set(name, data)
    File(f) => {
      let path = "\{f.dir}/\{name}"
      @fs.write_bytes_to_file(path, data) catch {
        @fs.IOError(msg) => raise io_failure("write", path, msg)
      }
    }
    Failpoint(fp) => {
      if fp.armed() {
        match fp.armed_kind.val {
          Some(FaultKind::TornWrite) => if fp.match_name(name) {
            fp.fired.val = true
            // A torn write: the first half of the payload reaches the
            // medium, then the operation fails. The engine must treat the
            // file as absent or truncated on recovery.
            let half = data.length() / 2
            write(Storage::Memory(fp.inner), name, data[0:half].to_owned())
            raise DbError::Fault("injected torn write: \{name}")
          }
          Some(FaultKind::LostWrite) => {
            if name == "WAL" {
              // The write reports success but nothing reaches the medium.
              fp.fired.val = true
              return
            }
          }
          _ => ()
        }
      }
      write(Storage::Memory(fp.inner), name, data)
    }
  }
}

/// Removes a file; removing a missing file is a no-op.
pub fn remove(storage : Storage, name : String) -> Unit raise DbError {
  match storage {
    Memory(m) => m.files.remove(name)
    File(f) => {
      let path = "\{f.dir}/\{name}"
      if @fs.path_exists(path) {
        @fs.remove_file(path) catch {
          @fs.IOError(msg) => raise io_failure("remove", path, msg)
        }
      }
    }
    Failpoint(fp) => remove(Storage::Memory(fp.inner), name)
  }
}

/// Lists file names with the given prefix, sorted by name.
pub fn list(storage : Storage, prefix : String) -> Array[String] raise DbError {
  match storage {
    Memory(m) => {
      let names : Array[String] = []
      for (k, _v) in m.files.iter() {
        if k.has_prefix(prefix) {
          names.push(k)
        }
      }
      names.sort()
      names
    }
    File(f) => {
      if !@fs.path_exists(f.dir) {
        @fs.create_dir(f.dir) catch {
          @fs.IOError(msg) => raise io_failure("create_dir", f.dir, msg)
        }
      }
      let entries =
        @fs.read_dir(f.dir) catch {
          @fs.IOError(msg) => raise io_failure("read_dir", f.dir, msg)
        }
      let all = entries.to_owned()
      let names : Array[String] = []
      for name in all {
        if name.has_prefix(prefix) {
          names.push(name)
        }
      }
      names.sort()
      names
    }
    Failpoint(fp) => list(Storage::Memory(fp.inner), prefix)
  }
}

/// True if the named file exists.
pub fn exists(storage : Storage, name : String) -> Bool raise DbError {
  match storage {
    Memory(m) => m.files.contains(name)
    File(f) => @fs.path_exists("\{f.dir}/\{name}")
    Failpoint(fp) => exists(Storage::Memory(fp.inner), name)
  }
}

/// Prepares the storage for use (creates the directory of a File storage).
pub fn ensure_ready(storage : Storage) -> Unit raise DbError {
  match storage {
    File(f) => {
      if !@fs.path_exists(f.dir) {
        @fs.create_dir(f.dir) catch {
          @fs.IOError(msg) => raise io_failure("create_dir", f.dir, msg)
        }
      }
    }
    _ => ()
  }
}
