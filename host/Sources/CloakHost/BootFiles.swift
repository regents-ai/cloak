import Foundation

/// The per-boot part of the guest root: the channel token, the rewriter key
/// and the run's settings, as an uncompressed newc archive the guest kernel
/// unpacks over the base root. These never touch the base image.
enum BootFiles {
    struct Entry {
        let path: String
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let data: Data
    }

    /// The base root followed by the entries. The kernel skips zero bytes
    /// between archives, so the base is padded to the next 4-byte boundary.
    static func initrd(base: Data, entries: [Entry]) -> Data {
        var out = base
        out.append(Data(count: (4 - out.count % 4) % 4))
        for (index, entry) in entries.enumerated() {
            append(&out, name: entry.path, inode: UInt32(index + 1), mode: 0o100000 | entry.mode,
                   uid: entry.uid, gid: entry.gid, data: entry.data)
        }
        append(&out, name: "TRAILER!!!", inode: 0, mode: 0, uid: 0, gid: 0, data: Data())
        return out
    }

    private static func append(
        _ out: inout Data, name: String, inode: UInt32, mode: UInt32, uid: UInt32, gid: UInt32, data: Data
    ) {
        let name = Data(name.utf8) + [0]
        let fields: [UInt32] = [
            inode, mode, uid, gid, 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(name.count), 0,
        ]
        out.append(Data(("070701" + fields.map { String(format: "%08X", $0) }.joined()).utf8))
        out.append(name)
        out.append(Data(count: (4 - out.count % 4) % 4))
        out.append(data)
        out.append(Data(count: (4 - out.count % 4) % 4))
    }
}
