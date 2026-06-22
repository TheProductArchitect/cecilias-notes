import Foundation

/// DEBUG-only print. No-op in release builds — the call site
/// compiles down to nothing, the format-string interpolation and
/// the `print` call are both elided. Use this in place of `print`
/// anywhere in the app sources so production builds stay silent
/// (and we don't ship App Store users a stream of `[Tag] …` lines
/// into the system log).
///
/// Naming: short on purpose — easier to drop in next to `print`
/// without breaking the column-aligned readability of nearby code.
@inlinable
nonisolated func dlog(
    _ items: Any...,
    separator: String = " ",
    terminator: String = "\n"
) {
    #if DEBUG
    let joined = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(joined, terminator: terminator)
    // Force-flush stdout so the log captures the exact final line
    // before a freeze — `print` buffers and the buffered tail
    // would be lost when the app stops responding, making freeze
    // diagnosis impossible. The flush adds a single fputc(EOF marker)
    // worth of overhead per line which is fine in DEBUG.
    fflush(stdout)
    #endif
}
