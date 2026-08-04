import Testing

/// Musashi is a process-global C core; every suite that constructs an M68K
/// (directly or via Machine) must run inside this serialized parent so no
/// two such suites overlap.
@Suite(.serialized)
enum MusashiSuites {}
