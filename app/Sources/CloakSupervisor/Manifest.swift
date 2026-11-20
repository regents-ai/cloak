import Foundation

/// The app's manifest, written into the bundle by app/build.sh: the release
/// and build, the one model (spec: no picker, no switching) with each of its
/// files pinned and where it downloads from, the memory the model and all of
/// Cloak need, and every part the supervisor runs, each in the bundle and
/// pinned by its sha256.
public struct Manifest: Codable, Sendable, Equatable {
    public enum Part: String, Codable, Sendable, CaseIterable {
        /// The guest's kernel and base root.
        case kernel, initrd
        /// tor and the libevent it loads.
        case tor, libevent
        /// The worker, its shaders built in, as llama-worker/install.sh
        /// built and signed it into its sandbox. It runs from a copy in the
        /// Application Support folder (`Layout.worker`).
        case worker
        /// NEAR mode's helper, cloak-near.
        case near
    }

    /// A part's path in the bundle's Resources folder, and its sha256.
    public struct Pin: Codable, Sendable, Equatable {
        public var part: Part
        public var path: String
        public var sha256: String

        public init(part: Part, path: String, sha256: String) {
            self.part = part
            self.path = path
            self.sha256 = sha256
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        /// One of the model's files: its path in the model's folder, its
        /// pinned size and sha256, and the one place the app downloads it
        /// from (`ModelDownload`), at its pinned repository and revision.
        public struct File: Codable, Sendable, Equatable {
            public var path: String
            public var size: Int
            public var sha256: String
            public var url: URL

            public init(path: String, size: Int, sha256: String, url: URL) {
                self.path = path
                self.size = size
                self.sha256 = sha256
                self.url = url
            }
        }

        public var name: String
        public var label: String
        public var files: [File]

        public init(name: String, label: String, files: [File]) {
            self.name = name
            self.label = label
            self.files = files
        }
    }

    public var release: String
    public var build: String
    /// The bytes the model needs, which the graphics must hold.
    public var modelMemory: UInt64
    /// The bytes everything Cloak runs needs, the model among it.
    public var cloakMemory: UInt64
    public var model: Model
    public var pins: [Pin]

    public init(release: String, build: String, modelMemory: UInt64, cloakMemory: UInt64, model: Model, pins: [Pin]) {
        self.release = release
        self.build = build
        self.modelMemory = modelMemory
        self.cloakMemory = cloakMemory
        self.model = model
        self.pins = pins
    }

    /// The manifest in the app's bundle, which pins each part once.
    public static func bundled() throws -> Manifest {
        let url = Bundle.main.resourceURL!.appending(path: "manifest.json")
        let manifest = try JSONDecoder.snakeCase.decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.pins.map(\.part).sorted(by: { $0.rawValue < $1.rawValue }) == Part.allCases.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return manifest
    }
}

/// Where Cloak's files are on this Mac: the bundle's Resources folder, which
/// holds every pinned part, and the Application Support folder.
public struct Layout: Sendable {
    public var bundle: URL
    public var support: URL

    public init(bundle: URL, support: URL) {
        self.bundle = bundle
        self.support = support
    }

    func url(_ pin: Manifest.Pin) -> URL {
        bundle.appending(path: pin.path)
    }

    func url(_ part: Manifest.Part, in manifest: Manifest) -> URL {
        url(manifest.pins.first { $0.part == part }!)
    }

    /// The model's folder: its files, which the worker checks against their
    /// pins at each start.
    public func model(_ manifest: Manifest) -> URL {
        support.appending(path: "models").appending(path: manifest.model.name)
    }

    /// NEAR mode's helper and its pin, which the app checks before each
    /// start of the helper (`Near`).
    public func near(_ manifest: Manifest) -> (helper: URL, sha256: String) {
        let pin = manifest.pins.first { $0.part == .near }!
        return (url(pin), pin.sha256)
    }

    /// The one place the worker runs from: its sandbox cannot start a
    /// program kept under ~/Documents or ~/Downloads, where the app may be.
    /// The supervisor copies the bundle's worker here at each Start when
    /// the file here is not the pinned one.
    var worker: URL { support.appending(path: "worker/cloak-rewriter-llama") }

    /// tor's lasting folder, as the stage 2 and 3 kits use it.
    var torData: URL { support.appending(path: "tor") }

    /// Where each guest's boot files are while it starts: in the owner-only
    /// control folder.
    var bootFiles: URL { support.appending(path: "control/boot") }

    /// The Chat window's sealed conversations, one file each.
    public var conversations: URL { support.appending(path: "conversations") }

    /// Development mode's wallet folder, which holds its deposit, sealed
    /// under the conversations' key; the key is in the keychain.
    public var wallet: URL { support.appending(path: "wallet") }

    /// The apps given a pass to the door (`Door`), sealed under the
    /// conversations' key: names, fingerprints of their passes, counts and
    /// times.
    public var agents: URL { support.appending(path: "agents") }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
