import Foundation

/// Owns the driver-level key swaps, via `hidutil`.
///
/// The swap list is a single global setting: one array that every tool on the
/// machine writes to. The previous version of this app replaced that array
/// wholesale on quit, which erased swaps it had never created — including the
/// ones declared elsewhere. Everything here is therefore read-modify-write:
/// this app only ever adds or removes its own entries.
///
/// The list does not survive a reboot, which is why `apply` runs at launch and
/// again whenever a keyboard connects.
enum HIDMapping {
    private struct Entry: Equatable {
        let src: UInt64
        let dst: UInt64
    }

    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Apply `swaps`, preserving any entry this app does not own.
    ///
    /// Ownership is by source key: an entry whose source matches one of our
    /// swaps is ours to replace, anything else is left exactly as found.
    @discardableResult
    static func apply(_ swaps: [Swap]) -> Bool {
        let ours = swaps.map { Entry(src: KeyNames.hidValue($0.from), dst: KeyNames.hidValue($0.to)) }
        let ourSources = Set(ours.map(\.src))
        let foreign = read().filter { !ourSources.contains($0.src) }
        let merged = foreign + ours

        Log.debug("HIDMapping.apply: \(ours.count) ours, \(foreign.count) left alone")
        return write(merged)
    }

    /// Remove only the entries matching `swaps`, leaving everything else in
    /// place. This is what runs on quit.
    @discardableResult
    static func remove(_ swaps: [Swap]) -> Bool {
        let ourSources = Set(swaps.map { KeyNames.hidValue($0.from) })
        let current = read()
        let kept = current.filter { !ourSources.contains($0.src) }

        if kept.count == current.count {
            Log.debug("HIDMapping.remove: nothing of ours present")
            return true
        }
        Log.debug("HIDMapping.remove: dropping \(current.count - kept.count), keeping \(kept.count)")
        return write(kept)
    }

    /// The swaps currently live in the driver, as a readable list.
    static func current() -> [Swap] {
        read().compactMap { entry in
            guard let from = KeyNames.usageFromHIDValue(entry.src),
                  let to = KeyNames.usageFromHIDValue(entry.dst)
            else { return nil }
            return Swap(from: from, to: to)
        }
    }

    // MARK: - hidutil

    private static func read() -> [Entry] {
        guard let text = run(["property", "--get", "UserKeyMapping"]) else { return [] }

        // hidutil prints an old-style (OpenStep) property list, not JSON, and
        // every value comes back as a string in that format.
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: Data(text.utf8), options: [], format: nil
        ) as? [[String: Any]] else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.debug("HIDMapping.read: could not parse hidutil output")
            }
            return []
        }

        return parsed.compactMap { dict in
            guard let src = number(dict[srcKey]), let dst = number(dict[dstKey]) else { return nil }
            return Entry(src: src, dst: dst)
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String { return UInt64(s) }
        return nil
    }

    private static func write(_ entries: [Entry]) -> Bool {
        let body = entries
            .map { "{\"\(srcKey)\":\($0.src),\"\(dstKey)\":\($0.dst)}" }
            .joined(separator: ",")
        return run(["property", "--set", "{\"UserKeyMapping\":[\(body)]}"]) != nil
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                Log.info("xkeys: hidutil \(arguments.first ?? "") failed (status \(process.terminationStatus))")
                return nil
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            Log.info("xkeys: could not run hidutil: \(error)")
            return nil
        }
    }
}
