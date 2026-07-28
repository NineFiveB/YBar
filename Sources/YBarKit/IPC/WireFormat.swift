import Foundation

/// The wire protocol between the `ybar` CLI client and the daemon.
///
/// Payload encoding is sketchybar-compatible: argv tokens are NUL-separated with a
/// trailing double-NUL. This is what makes `ybar --set foo label="hello world"` work
/// with arbitrary whitespace while keeping the client a dumb pipe.
/// Each direction is framed with a little-endian u32 byte length so the stream
/// transport (unix domain socket) has unambiguous message boundaries.
public enum WireFormat {
    public static let maxFrameLength: UInt32 = 8 * 1024 * 1024

    /// Serialize argv tokens into a NUL-separated payload with trailing double-NUL.
    public static func encode(arguments: [String]) -> Data {
        var data = Data()
        for argument in arguments {
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }
        data.append(0)
        return data
    }

    /// Parse a NUL-separated payload back into argv tokens.
    /// Parsing stops at the first empty token (the double-NUL terminator).
    public static func decode(payload: Data) -> [String] {
        var arguments: [String] = []
        var current = Data()
        for byte in payload {
            if byte == 0 {
                if current.isEmpty { break }
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        return arguments
    }

    /// Wrap a payload in a length frame.
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }

    /// Read the length prefix from the first 4 bytes of a frame header.
    public static func frameLength(header: Data) -> UInt32? {
        guard header.count >= 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let length = UInt32(littleEndian: value)
        guard length <= maxFrameLength else { return nil }
        return length
    }

    /// Socket path for a given instance name (the binary's basename, sketchybar-style,
    /// so a renamed binary runs as an independent instance).
    public static func socketPath(instanceName: String) -> String {
        let user = NSUserName()
        return "/tmp/\(instanceName)_\(user).socket"
    }

    /// Error reply convention (sketchybar-compatible): replies starting with "[!]"
    /// are printed to stderr by the client, which then exits non-zero.
    public static let errorPrefix = "[!]"
}
