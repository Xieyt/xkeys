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
    struct Entry: Equatable {
        let src: UInt64
        let dst: UInt64
    }

    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Apply `swaps`, preserving any entry this app does not own.
    ///
    /// Ownership is by source key: an entry whose source matches one of our
    /// swaps is ours to replace, anything else is left exactly as found.
    ///
    /// `product` aims the write at one keyboard. Without it the write lands
    /// on every keyboard, which is what an unscoped swap means.
    @discardableResult
    static func apply(_ swaps: [Swap], product: String? = nil) -> Bool {
        let ours = swaps.map { Entry(src: KeyNames.hidValue($0.from), dst: KeyNames.hidValue($0.to)) }
        let ourSources = Set(ours.map(\.src))
        let foreign = read(product: product).filter { !ourSources.contains($0.src) }
        let merged = foreign + ours

        Log.debug("HIDMapping.apply: \(ours.count) ours, \(foreign.count) left alone"
            + (product.map { " [\($0)]" } ?? ""))
        return write(merged, product: product)
    }

    /// Remove only the entries matching `swaps`, leaving everything else in
    /// place. This is what runs on quit.
    @discardableResult
    static func remove(_ swaps: [Swap], product: String? = nil) -> Bool {
        let ourSources = Set(swaps.map { KeyNames.hidValue($0.from) })
        let current = read(product: product)
        let kept = current.filter { !ourSources.contains($0.src) }

        if kept.count == current.count {
            Log.debug("HIDMapping.remove: nothing of ours present")
            return true
        }
        Log.debug("HIDMapping.remove: dropping \(current.count - kept.count), keeping \(kept.count)")
        return write(kept, product: product)
    }

    /// The swaps currently live in the driver, as a readable list.
    static func current(product: String? = nil) -> [Swap] {
        read(product: product).compactMap { entry in
            guard let from = KeyNames.usageFromHIDValue(entry.src),
                  let to = KeyNames.usageFromHIDValue(entry.dst)
            else { return nil }
            return Swap(from: from, to: to)
        }
    }

    /// Product names of every keyboard attached right now.
    ///
    /// Asked of `hidutil` rather than IOKit on purpose: this has to work from
    /// `xkeys keys` and `xkeys check` in a plain terminal, where opening the
    /// HID manager would be refused for lack of Input Monitoring.
    static func attachedKeyboards() -> [String] {
        guard let text = run(["property", "--matching", "keyboard", "--get", "Product"]) else { return [] }
        var names: [String] = []
        for line in text.split(separator: "\n").dropFirst() {
            // "<registry id>   Product   <name>" — the name may contain spaces.
            guard let range = line.range(of: "Product") else { continue }
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: - hidutil

    private static func read(product: String?) -> [Entry] {
        guard let text = run(matching(product) + ["--get", "UserKeyMapping"]) else { return [] }
        return entries(fromPropertyList: text)
    }

    private static func matching(_ product: String?) -> [String] {
        guard let product else { return ["property"] }
        return ["property", "--matching", #"{"Product":"\#(product)"}"#]
    }

    /// Split out from the `hidutil` call so the parsing can be exercised
    /// without touching the driver.
    ///
    /// Two shapes have to be read. Unmatched, hidutil prints one bare
    /// property list. Matched, it prints a table — a header line, then one
    /// row per matching device, each row carrying its own list. Several HID
    /// interfaces of one keyboard match at once, so a matched read returns
    /// several lists; they describe the same keyboard, so the entries are
    /// merged and de-duplicated by source key.
    ///
    /// Values are an old-style (OpenStep) property list, not JSON, and come
    /// back as strings in that format — so both NSNumber and String have to
    /// be accepted.
    static func entries(fromPropertyList text: String) -> [Entry] {
        var merged: [Entry] = []
        var seen = Set<UInt64>()
        var parsedAnything = false

        for block in parenthesisedBlocks(in: text) {
            guard let parsed = try? PropertyListSerialization.propertyList(
                from: Data(block.utf8), options: [], format: nil
            ) as? [[String: Any]] else { continue }
            parsedAnything = true
            for dict in parsed {
                guard let src = number(dict[srcKey]), let dst = number(dict[dstKey]) else { continue }
                if seen.insert(src).inserted { merged.append(Entry(src: src, dst: dst)) }
            }
        }

        if !parsedAnything, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.debug("HIDMapping.read: could not parse hidutil output")
        }
        return merged
    }

    /// Every balanced `( … )` run in the text, so a multi-device table can be
    /// taken apart without guessing where one list ends and the next begins.
    private static func parenthesisedBlocks(in text: String) -> [Substring] {
        var blocks: [Substring] = []
        var depth = 0
        var start: String.Index?

        for index in text.indices {
            switch text[index] {
            case "(":
                if depth == 0 { start = index }
                depth += 1
            case ")":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let from = start {
                    blocks.append(text[from...index])
                    start = nil
                }
            default:
                continue
            }
        }
        return blocks
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String { return UInt64(s) }
        return nil
    }

    private static func write(_ entries: [Entry], product: String?) -> Bool {
        let body = entries
            .map { "{\"\(srcKey)\":\($0.src),\"\(dstKey)\":\($0.dst)}" }
            .joined(separator: ",")
        return run(matching(product) + ["--set", "{\"UserKeyMapping\":[\(body)]}"]) != nil
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
