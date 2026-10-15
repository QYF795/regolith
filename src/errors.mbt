// errors.mbt
//
// The library-wide error type. Storage layers raise `Io` for filesystem
// failures, the SSTable/WAL readers raise `Corrupt` for data that fails
// integrity checks, and failpoint injection raises `Fault` (only reachable
// when a FailpointStorage is armed).

pub(all) suberror DbError {
  Io(String)
  Corrupt(String)
  Fault(String)
}
