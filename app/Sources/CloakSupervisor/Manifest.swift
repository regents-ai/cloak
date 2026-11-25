import CloakControl
import Foundation

/// The app's manifest, written into the bundle by app/build.sh: the release
/// and build, the memory all of Cloak needs, the one model that rewords (spec:
/// no picker, no switching, for rewording), every model that can answer Local
/// Llama chats (decision 21 in docs/plan.md), the rewording one among them,
/// each with its files pinned and where they download from, and every part
/// the supervisor runs, each in the bundle and pinned by its sha256.
public struct Manifest: Codable, Sendable, Equatable {
    public enum Part: String, Codable, Sendable, CaseIterable {
        /// The guest's kernel and base root.
        case kernel, initrd
        /// tor and the libevent it loads.
        case tor, libevent
        /// The llama.cpp worker, its shaders built in, as llama-worker/install.sh
        /// built and signed it into its sandbox. It runs from a copy in the
        /// Application Support folder (`Layout.worker`).
        case worker
        /// Optional pure-Swift vMLX worker (osaurus-ai/vmlx-swift) and its
        /// compiled Metal shader library for fast JANGH2 / MLX local models.
        case vmlxWorker = "vmlx_worker"
        case vmlxMetallib = "vmlx_metallib"
        /// NEAR mode's helper, cloak-near.
        case near
        /// Direct (no-Tor) host helper for Token Inference, cloak-sender.
        case sender

        /// Parts required in every release bundle regardless of whether the
        /// optional vMLX worker is bundled.
        static let core: [Part] = [.kernel, .initrd, .tor, .libevent, .worker, .near, .sender]
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

        /// An optional pinned GGUF LoRA adapter (e.g., AtomicChat's 44 MB
        /// uncensored adapter for Inkling 2 Mini).
        public struct Adapter: Codable, Sendable, Equatable {
            public var name: String
            public var label: String
            public var file: File

            public init(name: String, label: String, file: File) {
                self.name = name
                self.label = label
                self.file = file
            }

            public var repositoryURL: URL? {
                guard let scheme = file.url.scheme, let host = file.url.host() else { return nil }
                let parts = file.url.pathComponents.filter { $0 != "/" }
                guard parts.count >= 2 else { return nil }
                return URL(string: "\(scheme)://\(host)/\(parts[0])/\(parts[1])")
            }

            /// Synthetic `Manifest.Model` wrapper so `ModelDownload` can fetch
            /// and verify the adapter using the exact same resumable pipeline.
            public func asDownloadModel() -> Model {
                Model(name: name, label: label, memory: 0, files: [file])
            }
        }

        /// Which sandboxed local worker executes this model.
        public enum Engine: String, Codable, Sendable, Equatable {
            case llama
            case vmlx
        }

        public var name: String
        /// The model in plain words, such as "Qwen 3.5 9B".
        public var label: String
        /// Local worker engine (`llama` by default, or `vmlx` for JANGH2/MLX models).
        public var engine: Engine
        /// The bytes the model needs, which the graphics must hold.
        public var memory: UInt64
        public var files: [File]
        /// Optional opt-in uncensored LoRA adapter for this model.
        public var unfilteredLora: Adapter?

        public init(
            name: String, label: String, engine: Engine = .llama, memory: UInt64, files: [File],
            unfilteredLora: Adapter? = nil
        ) {
            self.name = name
            self.label = label
            self.engine = engine
            self.memory = memory
            self.files = files
            self.unfilteredLora = unfilteredLora
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            label = try container.decode(String.self, forKey: .label)
            engine = try container.decodeIfPresent(Engine.self, forKey: .engine) ?? .llama
            memory = try container.decode(UInt64.self, forKey: .memory)
            files = try container.decode([File].self, forKey: .files)
            unfilteredLora = try container.decodeIfPresent(Adapter.self, forKey: .unfilteredLora)
        }

        /// The bytes of its files: what a download fetches and the disk keeps.
        public var size: Int { files.reduce(0) { $0 + $1.size } }

        /// The repository page on the model's host (for example,
        /// `https://huggingface.co/ggml-org/Inkling-2-Mini-GGUF`), derived from
        /// the pinned file URLs so UI links always match the exact download source.
        public var repositoryURL: URL? {
            guard let url = files.first?.url, let scheme = url.scheme, let host = url.host() else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2 else { return nil }
            return URL(string: "\(scheme)://\(host)/\(parts[0])/\(parts[1])")
        }
    }

    public var release: String
    public var build: String
    /// The bytes everything Cloak runs needs, the rewording model among it.
    public var cloakMemory: UInt64
    /// The name of the model that rewords, one of `answerModels`.
    public var model: String
    /// Every model that can answer Local Llama chats, the least memory first.
    public var answerModels: [Model]
    public var pins: [Pin]

    public init(release: String, build: String, cloakMemory: UInt64, model: String, answerModels: [Model], pins: [Pin]) {
        self.release = release
        self.build = build
        self.cloakMemory = cloakMemory
        self.model = model
        self.answerModels = answerModels
        self.pins = pins
    }

    /// The model that rewords. It answers Local Llama chats too, unless
    /// another is chosen.
    public var rewordingModel: Model { answerModels.first { $0.name == model }! }

    /// Overhead (app + Tor/guest baseline) counted beside a standalone Local
    /// answer model when the rewriter worker is rested (so a 24 GB Mac can run
    /// the 13.6 GB Unsloth UD-Q3_K_XL Inkling 2 Mini without contending with
    /// Qwen 3.5 9B for Metal memory).
    public static let localOverhead: UInt64 = 2 << 30

    /// Whether this Mac can run `model` for Local Llama: for the rewording
    /// model, the check every Start makes; for any other Local model, checks
    /// standalone fit (when the rewriter doesn't fit concurrently, `Supervisor`
    /// rests the rewriter worker before waking the Local answer worker).
    func answerCheck(_ model: Model, hardware: Checks.Hardware) -> (Finding, Failure?) {
        if model.name == self.model {
            return Checks.hardwareCheck(hardware, model: rewordingModel.memory, cloak: cloakMemory)
        }
        return Checks.hardwareCheck(hardware, model: model.memory, cloak: model.memory + Self.localOverhead)
    }

    /// Whether `model` can stay loaded in Metal memory at the same time as the
    /// rewording model (for example on >=32–48 GB Macs).
    func canRunConcurrently(_ model: Model, hardware: Checks.Hardware) -> Bool {
        guard model.name != self.model else { return true }
        return Checks.hardwareCheck(
            hardware, model: rewordingModel.memory + model.memory, cloak: cloakMemory + model.memory
        ).1 == nil
    }

    /// The manifest in the app's bundle, which pins each part once and lists
    /// the model that rewords among those that answer.
    public static func bundled() throws -> Manifest {
        let url = Bundle.main.resourceURL!.appending(path: "manifest.json")
        let manifest = try JSONDecoder.snakeCase.decode(Manifest.self, from: Data(contentsOf: url))
        let hasVmlx = manifest.answerModels.contains { $0.engine == .vmlx }
        let expectedParts = Part.core + (hasVmlx ? [.vmlxWorker, .vmlxMetallib] : [])
        guard manifest.pins.map(\.part).sorted(by: { $0.rawValue < $1.rawValue })
            == expectedParts.sorted(by: { $0.rawValue < $1.rawValue }),
            manifest.answerModels.contains(where: { $0.name == manifest.model })
        else {
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

    /// A model's folder: its files, which the worker checks against their
    /// pins at each start.
    public func model(_ model: Manifest.Model) -> URL {
        support.appending(path: "models").appending(path: model.name)
    }

    /// An optional LoRA adapter's folder inside `models/` (readable by the
    /// sandboxed worker) and its GGUF file path.
    public func adapter(_ adapter: Manifest.Model.Adapter) -> URL {
        support.appending(path: "models").appending(path: adapter.name)
    }

    public func adapterFile(_ adapter: Manifest.Model.Adapter) -> URL {
        self.adapter(adapter).appending(path: adapter.file.path)
    }

    /// NEAR mode's helper and its pin, which the app checks before each
    /// start of the helper (`Near`).
    public func near(_ manifest: Manifest) -> (helper: URL, sha256: String) {
        let pin = manifest.pins.first { $0.part == .near }!
        return (url(pin), pin.sha256)
    }

    /// The one place the llama.cpp worker runs from: its sandbox cannot start a
    /// program kept under ~/Documents or ~/Downloads, where the app may be.
    /// The supervisor copies the bundle's worker here at each Start when
    /// the file here is not the pinned one.
    var worker: URL { support.appending(path: "worker/cloak-rewriter-llama") }

    /// The pure-Swift vMLX worker and its sibling Metal shader library inside
    /// Application Support (`worker/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`).
    var vmlxWorker: URL { support.appending(path: "worker/cloak-worker-vmlx") }
    var vmlxMetallib: URL { support.appending(path: "worker/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib") }

    /// tor's lasting folder, as the stage 2 and 3 kits use it.
    var torData: URL { support.appending(path: "tor") }

    /// Where each guest's boot files are while it starts: in the owner-only
    /// control folder.
    var bootFiles: URL { support.appending(path: "control/boot") }

    /// Owner-only Unix socket for the optional direct (no-Tor) host `cloak-sender`.
    var directSenderSocket: URL { support.appending(path: "control/sender.sock") }

    /// The Chat window's sealed conversations, one file each.
    public var conversations: URL { support.appending(path: "conversations") }

    /// Token Inference's wallet folder, which holds its deposit, sealed
    /// under the conversations' key; the key is in the keychain.
    public var wallet: URL { support.appending(path: "wallet") }

    /// V's payment disk's image (`PaymentDisk`), in an owner-only folder:
    /// the guest's payer's encrypted disk, attached to each run's guest.
    var paymentDisk: URL { support.appending(path: "pay/disk.img") }

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
