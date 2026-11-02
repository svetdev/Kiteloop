/// The helpers both test targets share — `eventually`, `makeTemporaryDirectory`,
/// `ScriptedSubprocessRunner`, `RepositoryRoot` — live in the package's
/// `KiteloopTestSupport` target, once. Re-exported here so every file in this
/// target sees them without an import of its own.
@_exported import KiteloopTestSupport
