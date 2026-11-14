import Foundation

/// The app's manifest, written into the bundle by app/build.sh: the release
/// and build, the one model (spec: no picker, no switching), the memory
/// floor, and every part the supervisor runs, each pinned by its sha256.
public struct Manifest: Codable, Sendable, Equatable {
    public enum Part: String, Codable, Sendable, CaseIterable {
        /// The guest's kernel and base root, in the bundle.
        case kernel, initrd
        /// tor and the libevent it loads, in the bundle.
        case tor, libevent
        /// The worker, its shaders built in, installed by
        /// llama-worker/install.sh in the Application Support folder, where
        /// its sandbox lets it run.
        case worker
    }

    public enum Place: String, Codable, Sendable {
        case bundle
        case support
    }

    public struct Pin: Codable, Sendable, Equatable {
        public var part: Part
        public var place: Place
        public var path: String
        public var sha256: String

        public init(part: Part, place: Place, path: String, sha256: String) {
            self.part = part
            self.place = place
            self.path = path
            self.sha256 = sha256
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String
            public var size: Int

            public init(path: String, size: Int) {
                self.path = path
                self.size = size
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
    public var minimumMemory: UInt64
    public var model: Model
    public var pins: [Pin]

    public init(release: String, build: String, minimumMemory: UInt64, model: Model, pins: [Pin]) {
        self.release = release
        self.build = build
        self.minimumMemory = minimumMemory
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

/// Where the manifest's places are on this Mac.
public struct Layout: Sendable {
    public var bundle: URL
    public var support: URL

    public init(bundle: URL, support: URL) {
        self.bundle = bundle
        self.support = support
    }

    func url(_ pin: Manifest.Pin) -> URL {
        (pin.place == .bundle ? bundle : support).appending(path: pin.path)
    }

    func url(_ part: Manifest.Part, in manifest: Manifest) -> URL {
        url(manifest.pins.first { $0.part == part }!)
    }

    func model(_ manifest: Manifest) -> URL {
        support.appending(path: "models").appending(path: manifest.model.name)
    }

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
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
