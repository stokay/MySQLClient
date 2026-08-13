import Foundation

/// Writes a file without ever touching whatever's already at the
/// destination path until the write has fully succeeded.
///
/// Every writer in this app that opens a raw `FileHandle` directly on a
/// user-chosen `outputFileURL` used to truncate that path immediately (via
/// `FileManager.createFile`) before any real data existed, and delete it on
/// any failure or cancellation. That's fine the first time a path is used,
/// but catastrophic the second: if the user picks an *existing* file (a
/// backup tool's most common case — overwriting yesterday's dump, or
/// retrying into the same path after a first attempt failed), a failed or
/// cancelled run destroys the previous, still-good file with no way back.
enum AtomicFileWriter {
    enum WriteError: Error, LocalizedError {
        /// `destinationURL` was never touched.
        case cannotOpenTemporaryFile(URL, underlying: Error?)

        /// Without this, Swift's default `NSError` bridging surfaces this
        /// case as an opaque "The operation couldn't be completed.
        /// (…WriteError error 0.)". `url` here lives in this app's own
        /// sandbox-exempt temporary directory, so a failure at this exact
        /// step (as opposed to the later `replaceItemAt` onto the real,
        /// user-chosen destination) points at something generic like low
        /// disk space rather than a permissions problem.
        var errorDescription: String? {
            switch self {
            case .cannotOpenTemporaryFile(_, let underlying):
                if let underlying {
                    return String(localized: "Couldn't create a temporary file: \(underlying.localizedDescription)")
                }
                return String(localized: "Couldn't create a temporary file. Please check that there's enough free disk space and try again.")
            }
        }
    }

    /// Creates a temporary file in this app's own sandbox-exempt temporary
    /// directory (`FileManager.default.temporaryDirectory` — always
    /// writable under App Sandbox, no entitlement or panel needed), hands
    /// `body` a writable handle to it, and — only if `body` returns
    /// normally — closes it and atomically swaps it onto `destinationURL`
    /// via `FileManager.replaceItemAt(_:withItemAt:)`, which handles both
    /// "destination already exists" and "destination doesn't exist yet".
    ///
    /// A same-directory sibling of `destinationURL` was tried first and
    /// abandoned: it relied on `NSSavePanel`'s Powerbox grant for
    /// `destinationURL` also covering a *differently-named* new file in the
    /// same folder, which turned out to be unreliable in practice — a real
    /// failure writing to an iCloud Drive-synced Desktop folder even right
    /// after a fresh, legitimate save-panel grant for that exact
    /// destination (no kernel sandbox denial logged at all; iCloud's
    /// FileProvider layer just silently refused the new sibling). Using
    /// `replaceItemAt` to write straight onto `destinationURL` itself — the
    /// one URL that actually was granted — sidesteps that: it's Apple's own
    /// primitive for correctly replacing files at FileProvider-backed
    /// (iCloud, network share, …) locations.
    ///
    /// If `body` throws for any reason (including cancellation) or the
    /// temporary file can't even be created, the temporary file is
    /// discarded and `destinationURL` is left exactly as it was — never
    /// truncated, never deleted, never partially overwritten.
    static func write(
        to destinationURL: URL,
        body: @MainActor (FileHandle) async throws -> Void
    ) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WriteError.cannotOpenTemporaryFile(tempURL, underlying: nil)
        }
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.cannotOpenTemporaryFile(tempURL, underlying: error)
        }

        do {
            try await body(fileHandle)
            try fileHandle.close()
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            // Defense in depth: clear the hidden flag even if it somehow
            // got set (e.g. by `replaceItemAt`'s own internal swap), so a
            // successful write is never left invisible in Finder.
            var finalURL = destinationURL
            var resourceValues = URLResourceValues()
            resourceValues.isHidden = false
            try? finalURL.setResourceValues(resourceValues)
        } catch {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
