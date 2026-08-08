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
    enum WriteError: Error {
        /// `destinationURL` was never touched.
        case cannotOpenTemporaryFile(URL, underlying: Error?)
    }

    /// Creates a temporary sibling of `destinationURL` in the same
    /// directory (not a system temp directory — this app is sandboxed and
    /// relies on `NSSavePanel`'s implicit Powerbox grant for the chosen
    /// path, which a same-directory sibling stays covered by), hands
    /// `body` a writable handle to it, and — only if `body` returns
    /// normally — closes it and atomically swaps it onto `destinationURL`
    /// via `FileManager.replaceItemAt(_:withItemAt:)`, which handles both
    /// "destination already exists" and "destination doesn't exist yet".
    ///
    /// If `body` throws for any reason (including cancellation) or the
    /// temporary file can't even be created, the temporary file is
    /// discarded and `destinationURL` is left exactly as it was — never
    /// truncated, never deleted, never partially overwritten.
    static func write(
        to destinationURL: URL,
        body: @MainActor (FileHandle) async throws -> Void
    ) async throws {
        let directory = destinationURL.deletingLastPathComponent()
        // Deliberately no leading dot: macOS auto-sets the BSD "hidden"
        // flag (UF_HIDDEN) on any file whose name starts with a dot at
        // creation time, and `replaceItemAt` carries that flag over onto
        // the destination — the final file silently vanishes from Finder
        // (while still showing up fine in `ls`/Terminal) even though its
        // name has no dot anymore.
        let tempURL = directory.appendingPathComponent("\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")

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
