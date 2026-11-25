import Foundation

/// Curated open-source / public-domain offline datasets that Cloak can download
/// progressively from minimum to maximum directly into a local folder on this Mac.
public enum OfflineDatasetID: String, CaseIterable, Identifiable, Codable, Sendable {
    case tinfoilkit
    case kiwix
    case devdocs
    case courtlistener

    public var id: String { rawValue }
}

/// One direct-download file belonging to an `OfflineDataset`, unlocked at `minLevel`.
public struct OfflineDatasetFile: Identifiable, Equatable, Sendable {
    public let id: String
    public let filename: String
    /// Directory or file name checked on disk to treat this item as installed
    /// (differs from `filename` when `extractTarGz` unpacks an archive).
    public let installedName: String
    public let url: URL
    public let expectedBytes: Int64
    public let minLevel: Int
    public let extractTarGz: Bool

    public init(
        id: String,
        filename: String,
        installedName: String? = nil,
        url: URL,
        expectedBytes: Int64,
        minLevel: Int,
        extractTarGz: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.installedName = installedName ?? filename
        self.url = url
        self.expectedBytes = expectedBytes
        self.minLevel = minLevel
        self.extractTarGz = extractTarGz
    }
}

/// One step on a dataset's Minimum → Maximum scale slider.
public struct OfflineDatasetTier: Identifiable, Equatable, Sendable {
    public let level: Int
    public let label: String
    public let summary: String

    public var id: Int { level }

    public init(level: Int, label: String, summary: String) {
        self.level = level
        self.label = label
        self.summary = summary
    }
}

/// Metadata and progressive additive file tiers for an offline dataset.
public struct OfflineDataset: Identifiable, Equatable, Sendable {
    public let id: OfflineDatasetID
    public let name: String
    public let subtitle: String
    public let websiteURL: URL
    public let sourceURL: URL
    public let sourceLabel: String
    /// True when downloaded files are plain text/JSON searchable directly via
    /// Local Mode's Approved Local Folders.
    public let searchableInLocalMode: Bool
    public let tiers: [OfflineDatasetTier]
    public let files: [OfflineDatasetFile]

    public var minLevel: Int { tiers.first?.level ?? 1 }
    public var maxLevel: Int { tiers.last?.level ?? 1 }
    public var hasScaleSlider: Bool { maxLevel > minLevel }

    public func tier(for level: Int) -> OfflineDatasetTier {
        tiers.first { $0.level == level } ?? tiers[0]
    }

    public func files(upTo level: Int) -> [OfflineDatasetFile] {
        files.filter { $0.minLevel <= level }
    }

    public func totalBytes(upTo level: Int) -> Int64 {
        files(upTo: level).reduce(0) { $0 + $1.expectedBytes }
    }

    public func missingFiles(upTo level: Int, installed: Set<String>) -> [OfflineDatasetFile] {
        files(upTo: level).filter { !installed.contains($0.installedName) }
    }

    public func missingBytes(upTo level: Int, installed: Set<String>) -> Int64 {
        missingFiles(upTo: level, installed: installed).reduce(0) { $0 + $1.expectedBytes }
    }

    /// Highest contiguous tier level (1...maxLevel) whose files are all present
    /// on disk, or `0` when no full tier is installed yet.
    public func highestCompleteLevel(installed: Set<String>) -> Int {
        var highest = 0
        for tier in tiers.sorted(by: { $0.level < $1.level }) {
            let required = files(upTo: tier.level)
            if !required.isEmpty && required.allSatisfy({ installed.contains($0.installedName) }) {
                highest = tier.level
            } else {
                break
            }
        }
        return highest
    }

    /// Human-readable compact byte size (e.g. `540 KB`, `15 MB`, `6.9 GB`).
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : (bytes < 1_000_000_000 ? [.useMB] : [.useGB])
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    /// All downloadable datasets shipped in Settings → Offline Data.
    public static let all: [OfflineDataset] = [tinfoilkit, kiwix, devdocs, courtlistener]

    // MARK: - Curated Datasets (verified direct HTTPS URLs & byte sizes)

    public static let tinfoilkit = OfflineDataset(
        id: .tinfoilkit,
        name: "Tinfoil Kit",
        subtitle: "Open-source offline library with Wikipedia, medical and repair guides, offline maps, and local AI in one portable folder (v1.0.0 launcher & setup kit).",
        websiteURL: URL(string: "https://github.com/tudor-city-ventures/tinfoil-kit")!,
        sourceURL: URL(string: "https://github.com/tudor-city-ventures/tinfoil-kit")!,
        sourceLabel: "GitHub",
        searchableInLocalMode: false,
        tiers: [
            OfflineDatasetTier(level: 1, label: "Kit v1.0.0", summary: "TinfoilKit.tar.gz unpacked with SETUP & Open launchers"),
        ],
        files: [
            OfflineDatasetFile(
                id: "tinfoilkit-v1",
                filename: "TinfoilKit.tar.gz",
                installedName: "TinfoilKit",
                url: URL(string: "https://github.com/tudor-city-ventures/tinfoil-kit/releases/download/v1.0.0/TinfoilKit.tar.gz")!,
                expectedBytes: 12_213_157,
                minLevel: 1,
                extractTarGz: true),
        ])

    public static let kiwix = OfflineDataset(
        id: .kiwix,
        name: "Kiwix Library",
        subtitle: "Modular offline ZIM archives (WikiMed, Stack Exchange, iFixit, Wikipedia) readable with the open-source Kiwix Mac app.",
        websiteURL: URL(string: "https://library.kiwix.org")!,
        sourceURL: URL(string: "https://github.com/kiwix/kiwix-apple")!,
        sourceLabel: "Kiwix",
        searchableInLocalMode: false,
        tiers: [
            OfflineDatasetTier(level: 1, label: "Minimal", summary: "WikiMed medical reference"),
            OfflineDatasetTier(level: 2, label: "Compact", summary: "+ InfoSec Stack Exchange"),
            OfflineDatasetTier(level: 3, label: "Standard", summary: "+ Top English Wikipedia & iFixit repair guides"),
            OfflineDatasetTier(level: 4, label: "Maximum", summary: "+ Unix/Linux Stack Exchange & Full English Wikipedia"),
        ],
        files: [
            OfflineDatasetFile(
                id: "kiwix-wikimed",
                filename: "wikipedia_en_medicine_mini_2026-10.zim",
                url: URL(string: "https://download.kiwix.org/zim/wikipedia/wikipedia_en_medicine_mini_2026-10.zim")!,
                expectedBytes: 174_400_000,
                minLevel: 1),
            OfflineDatasetFile(
                id: "kiwix-security-se",
                filename: "security.stackexchange.com_en_all_2026-10.zim",
                url: URL(string: "https://download.kiwix.org/zim/stack_exchange/security.stackexchange.com_en_all_2026-10.zim")!,
                expectedBytes: 439_800_000,
                minLevel: 2),
            OfflineDatasetFile(
                id: "kiwix-wiki-top",
                filename: "wikipedia_en_top_nopic_2026-09.zim",
                url: URL(string: "https://download.kiwix.org/zim/wikipedia/wikipedia_en_top_nopic_2026-09.zim")!,
                expectedBytes: 2_745_900_000,
                minLevel: 3),
            OfflineDatasetFile(
                id: "kiwix-ifixit",
                filename: "ifixit_en_all_2025-12.zim",
                url: URL(string: "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim")!,
                expectedBytes: 3_570_700_000,
                minLevel: 3),
            OfflineDatasetFile(
                id: "kiwix-unix-se",
                filename: "unix.stackexchange.com_en_all_2026-10.zim",
                url: URL(string: "https://download.kiwix.org/zim/stack_exchange/unix.stackexchange.com_en_all_2026-10.zim")!,
                expectedBytes: 1_316_300_000,
                minLevel: 4),
            OfflineDatasetFile(
                id: "kiwix-wiki-all",
                filename: "wikipedia_en_all_nopic_2026-06.zim",
                url: URL(string: "https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic_2026-06.zim")!,
                expectedBytes: 52_690_700_000,
                minLevel: 4),
        ])

    public static let devdocs = OfflineDataset(
        id: .devdocs,
        name: "DevDocs",
        subtitle: "Offline developer & API documentation JSON bundles (CLI, Web, Python, SQL, Systems). Searchable locally in Local Mode.",
        websiteURL: URL(string: "https://devdocs.io")!,
        sourceURL: URL(string: "https://github.com/freeCodeCamp/devdocs")!,
        sourceLabel: "GitHub",
        searchableInLocalMode: true,
        tiers: [
            OfflineDatasetTier(level: 1, label: "Minimal", summary: "Git, Bash, HTTP, Markdown, jq"),
            OfflineDatasetTier(level: 2, label: "Compact", summary: "+ JavaScript, TypeScript, HTML, CSS, Python 3.13, Node, React"),
            OfflineDatasetTier(level: 3, label: "Standard", summary: "+ Go, C, PostgreSQL 17, SQLite, Docker, Kubernetes"),
            OfflineDatasetTier(level: 4, label: "Maximum", summary: "+ Rust & C++ full reference"),
        ],
        files: [
            devdocsFile("git", bytes: 6_334_850, level: 1),
            devdocsFile("bash", bytes: 958_336, level: 1),
            devdocsFile("http", bytes: 7_047_986, level: 1),
            devdocsFile("markdown", bytes: 33_555, level: 1),
            devdocsFile("jq", bytes: 311_991, level: 1),

            devdocsFile("javascript", bytes: 12_370_828, level: 2),
            devdocsFile("typescript", bytes: 1_947_534, level: 2),
            devdocsFile("html", bytes: 5_529_381, level: 2),
            devdocsFile("css", bytes: 15_878_611, level: 2),
            devdocsFile("python~3.13", filename: "python-3.13.json", bytes: 19_127_630, level: 2),
            devdocsFile("node", bytes: 6_856_259, level: 2),
            devdocsFile("react", bytes: 8_981_282, level: 2),

            devdocsFile("go", bytes: 4_973_652, level: 3),
            devdocsFile("c", bytes: 5_128_537, level: 3),
            devdocsFile("postgresql~17", filename: "postgresql-17.json", bytes: 8_336_477, level: 3),
            devdocsFile("sqlite", bytes: 16_104_928, level: 3),
            devdocsFile("docker", bytes: 4_328_150, level: 3),
            devdocsFile("kubernetes", bytes: 1_302_728, level: 3),

            devdocsFile("rust", bytes: 70_119_547, level: 4),
            devdocsFile("cpp", bytes: 44_891_108, level: 4),
        ])

    public static let courtlistener = OfflineDataset(
        id: .courtlistener,
        name: "CourtListener Bulk Data",
        subtitle: "Free Law Project public-domain U.S. courts, judges, citation graphs, and case law opinions (compressed CSV).",
        websiteURL: URL(string: "https://www.courtlistener.com/help/api/bulk/")!,
        sourceURL: URL(string: "https://github.com/freelawproject/courtlistener")!,
        sourceLabel: "Docs",
        searchableInLocalMode: false,
        tiers: [
            OfflineDatasetTier(level: 1, label: "Minimal", summary: "U.S. Courts & Judges directory"),
            OfflineDatasetTier(level: 2, label: "Compact", summary: "+ Full Case Citation Graph"),
            OfflineDatasetTier(level: 3, label: "Standard", summary: "+ Opinion Clusters & Case Metadata"),
            OfflineDatasetTier(level: 4, label: "Maximum", summary: "+ Full U.S. Court Opinions text archive"),
        ],
        files: [
            OfflineDatasetFile(
                id: "cl-courts",
                filename: "courts-2026-09-30.csv.bz2",
                url: URL(string: "https://com-courtlistener-storage.s3-us-west-2.amazonaws.com/bulk-data/courts-2026-09-30.csv.bz2")!,
                expectedBytes: 80_000,
                minLevel: 1),
            OfflineDatasetFile(
                id: "cl-people",
                filename: "people-db-people-2026-09-30.csv.bz2",
                url: URL(string: "https://com-courtlistener-storage.s3-us-west-2.amazonaws.com/bulk-data/people-db-people-2026-09-30.csv.bz2")!,
                expectedBytes: 460_000,
                minLevel: 1),
            OfflineDatasetFile(
                id: "cl-citations",
                filename: "citation-map-2026-09-30.csv.bz2",
                url: URL(string: "https://com-courtlistener-storage.s3-us-west-2.amazonaws.com/bulk-data/citation-map-2026-09-30.csv.bz2")!,
                expectedBytes: 533_110_000,
                minLevel: 2),
            OfflineDatasetFile(
                id: "cl-clusters",
                filename: "opinion-clusters-2026-09-30.csv.bz2",
                url: URL(string: "https://com-courtlistener-storage.s3-us-west-2.amazonaws.com/bulk-data/opinion-clusters-2026-09-30.csv.bz2")!,
                expectedBytes: 2_467_610_000,
                minLevel: 3),
            OfflineDatasetFile(
                id: "cl-opinions",
                filename: "opinions-2026-09-30.csv.bz2",
                url: URL(string: "https://com-courtlistener-storage.s3-us-west-2.amazonaws.com/bulk-data/opinions-2026-09-30.csv.bz2")!,
                expectedBytes: 55_252_640_000,
                minLevel: 4),
        ])

    private static func devdocsFile(_ slug: String, filename: String? = nil, bytes: Int64, level: Int) -> OfflineDatasetFile {
        OfflineDatasetFile(
            id: "devdocs-\(slug)",
            filename: filename ?? "\(slug).json",
            url: URL(string: "https://documents.devdocs.io/\(slug)/db.json")!,
            expectedBytes: bytes,
            minLevel: level)
    }
}
