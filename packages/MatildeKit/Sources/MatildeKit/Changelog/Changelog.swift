import Foundation

// WHAT'S NEW: the user-facing changelog, one Markdown file per release in changelog/ at the repo
// root. The website (/changelog), the Mac app (Help → What's New in Matilde), the iPhone app
// (Settings → What's New) and the update dialog all read the same files; the apps bundle a copy at
// build time, so it works offline. Format, also checked by apps/macos/scripts/changelog.py:
//
//     ---
//     version: 0.3.3
//     covers: 0.3.0 to 0.3.3          (optional: small releases folded into one entry)
//     date: 2026-11-22
//     title: Your AI tools, in plain sight
//     matilde: I like knowing who else is in the room.   (optional margin one-liner)
//     ---
//
//     One short, warm paragraph.
//
//     - A few plain bullets, with **bold** and [links](https://matilde.page) at most.

public struct ChangelogEntry: Identifiable, Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        /// Inline Markdown (bold, italics, links).
        case paragraph(String)
        case bullets([String])
    }

    public let version: String
    public let covers: String?
    /// The release day, at midnight UTC. Format it with `Changelog.dateText(_:)`.
    public let date: Date
    public let title: String
    public let matilde: String?
    public let blocks: [Block]

    public var id: String { version }
    /// "0.3.3", or "0.1.0 to 0.1.3" for an entry covering several small releases.
    public var versionLabel: String { covers ?? version }
    /// "Version 0.3.3" or "Versions 0.1.0 to 0.1.3".
    public var versionTitle: String { covers.map { "Versions \($0)" } ?? "Version \(version)" }

    public init(version: String, covers: String? = nil, date: Date, title: String, matilde: String? = nil, blocks: [Block]) {
        self.version = version
        self.covers = covers
        self.date = date
        self.title = title
        self.matilde = matilde
        self.blocks = blocks
    }
}

public enum Changelog {
    /// The folder the apps bundle the entries in: `Changelog` (Mac, copied by build-app.sh) or
    /// `changelog` (iPhone, a folder reference in project.yml).
    public static let bundleFolders = ["Changelog", "changelog"]

    /// Every entry in the bundle, newest first; empty when none were bundled (e.g. `swift run`).
    public static func bundled(in bundle: Bundle = .main) -> [ChangelogEntry] {
        for name in bundleFolders {
            if let url = bundle.url(forResource: name, withExtension: nil) {
                let entries = load(from: url)
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    /// Every `<version>.md` in the folder, newest first. Files that don't parse are skipped.
    public static func load(from directory: URL) -> [ChangelogEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = files
            .filter { $0.pathExtension == "md" && parseVersion($0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url -> ChangelogEntry? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let entry = parse(text), entry.version == url.deletingPathExtension().lastPathComponent else { return nil }
                return entry
            }
        return entries.sorted { isNewer($0.version, than: $1.version) }
    }

    public static func parse(_ text: String) -> ChangelogEntry? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        lines.removeSubrange(0...end)
        guard let version = fields["version"], parseVersion(version) != nil,
              let dateText = fields["date"], let date = parseDate(dateText),
              let title = fields["title"], !title.isEmpty else { return nil }
        let blocks = parseBlocks(lines.joined(separator: "\n"))
        guard !blocks.isEmpty else { return nil }
        return ChangelogEntry(version: version, covers: nonEmpty(fields["covers"]), date: date, title: title,
                              matilde: nonEmpty(fields["matilde"]), blocks: blocks)
    }

    /// Paragraphs and bullet lists. A line starting with "- " is a bullet; any other line continues
    /// the bullet or paragraph above it; a blank line ends both. Same rules as changelog.py.
    static func parseBlocks(_ body: String) -> [ChangelogEntry.Block] {
        var blocks: [ChangelogEntry.Block] = []
        var open = false
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { open = false; continue }
            if line.hasPrefix("- ") {
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if open, case .bullets(var items) = blocks.last {
                    items.append(item)
                    blocks[blocks.count - 1] = .bullets(items)
                } else {
                    blocks.append(.bullets([item]))
                }
            } else if open, let last = blocks.last {
                switch last {
                case .paragraph(let text): blocks[blocks.count - 1] = .paragraph(text + " " + line)
                case .bullets(var items):
                    items[items.count - 1] += " " + line
                    blocks[blocks.count - 1] = .bullets(items)
                }
            } else {
                blocks.append(.paragraph(line))
            }
            open = true
        }
        return blocks
    }

    // MARK: Versions

    /// (major, minor, patch) for "0.3.3"; nil for anything else.
    public static func parseVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return false }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    /// The entry to show once after an update, or nil. Fresh installs (no earlier launch and nothing
    /// recorded) see nothing; the welcome note greets them instead. Afterwards the caller records
    /// `current` as seen, whether or not anything was shown.
    public static func entryToAnnounce(current: String, lastSeen: String?, launchedBefore: Bool,
                                       entries: [ChangelogEntry]) -> ChangelogEntry? {
        if let lastSeen {
            guard isNewer(current, than: lastSeen) else { return nil }
        } else if !launchedBefore {
            return nil
        }
        return entries.first { $0.version == current }
    }

    // MARK: Dates

    private static let utc = TimeZone(identifier: "UTC")!

    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// "22 November 2026", like the website, for the release day whatever the time zone.
    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = utc
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// "22 Nov 2026", for sidebar rows.
    public static func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = utc
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
