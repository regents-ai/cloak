import Darwin
import Foundation

/// What Cloak holds in memory now, part by part: the app, each process it
/// started (tor and the worker), and the guest's virtual machine, which
/// macOS runs for the app as a helper of its own rather than as its child.
/// Each figure is the process's physical footprint, the one Activity
/// Monitor shows, which counts the graphics memory a resident size misses.
public struct Memory: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var name: String
        /// Nil when it could not be read.
        public var footprint: UInt64?
    }

    public var parts: [Part]

    /// Every part together; nil unless each one was read.
    public var total: UInt64? {
        parts.reduce(0) { total, part in
            guard let total, let footprint = part.footprint else { return nil }
            return total + footprint
        }
    }

    /// Each part's figure and the total, for the technical detail.
    var detail: String {
        let each = parts.map { "\($0.name) \($0.footprint.map(Self.text) ?? "cannot be read")" }
        return "memory: \(each.joined(separator: ", ")); \(total.map { "\(Self.text($0)) in all" } ?? "no total, as a part cannot be read")"
    }

    /// `bytes` as Activity Monitor shows memory: "7.2 GB".
    public static func text(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    /// The name of the process macOS runs each virtual machine in.
    static let virtualMachine = "com.apple.Virtualization.VirtualMachine"

    /// Reads every part now. With `guest`, a guest has been started, so its
    /// virtual machine must be among them: when none is found, that part
    /// cannot be read. A process that ends before it is read holds nothing,
    /// and is left out.
    static func read(guest: Bool) -> Memory {
        let app = getpid()
        // This process has not ended.
        var parts = [part("app", app)!]
        if let started = children(of: app) {
            parts += started.compactMap { part(name(of: $0), $0) }
        } else {
            parts.append(Part(name: "processes it started", footprint: nil))
        }
        let machines = virtualMachines(for: app)?.compactMap { part("virtual machine", $0) }
        if let machines, !machines.isEmpty || !guest {
            parts += machines
        } else {
            parts.append(Part(name: "virtual machine", footprint: nil))
        }
        return Memory(parts: parts)
    }

    /// The process's part; nil once it has ended.
    private static func part(_ name: String, _ pid: pid_t) -> Part? {
        var usage = rusage_info_v4()
        let (read, error) = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { (proc_pid_rusage(pid, RUSAGE_INFO_V4, $0), errno) }
        }
        if read == 0 { return Part(name: name, footprint: usage.ri_phys_footprint) }
        return error == ESRCH ? nil : Part(name: name, footprint: nil)
    }

    /// The processes `pid` started that have not ended; nil when they
    /// cannot be listed.
    private static func children(of pid: pid_t) -> [pid_t]? {
        list { proc_listchildpids(pid, $0, $1) }
    }

    /// The virtual machine processes macOS runs for `pid`: launchd starts
    /// each, and macOS holds the process responsible for `pid` responsible
    /// for it too, as scripts/boot.py finds the guest's. Nil when that or
    /// the processes cannot be found.
    private static func virtualMachines(for pid: pid_t) -> [pid_t]? {
        let owner = responsibleProcess(pid)
        guard owner > 0 else { return nil }
        return list { proc_listallpids($0, $1) }?.filter {
            responsibleProcess($0) == owner && path(of: $0)?.hasSuffix("/" + virtualMachine) == true
        }
    }

    /// A list of processes from `call`, which fills a buffer of the given
    /// size in bytes and returns how many it wrote, or with no buffer how
    /// many there are about to be.
    private static func list(_ call: (UnsafeMutableRawPointer?, Int32) -> Int32) -> [pid_t]? {
        let expected = call(nil, 0)
        guard expected >= 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let count = pids.withUnsafeMutableBytes { call($0.baseAddress, Int32($0.count)) }
        return count >= 0 ? Array(pids.prefix(Int(count))) : nil
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    private static func name(of pid: pid_t) -> String {
        path(of: pid).map { URL(filePath: $0).lastPathComponent } ?? "process \(pid)"
    }
}

/// The process macOS holds responsible for `pid`: the app it belongs to.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibleProcess(_ pid: pid_t) -> pid_t
