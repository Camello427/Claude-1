import Foundation

/// The protobuf message Chromecasts speak (`CastMessage` from cast_channel.proto), hand-encoded
/// so the app doesn't need a protobuf library. Only the string-payload form is used.
struct CastMessage {
    var sourceId: String
    var destinationId: String
    var namespace: String
    var payload: String

    func encoded() -> Data {
        var out: [UInt8] = []
        out.append(0x08); out.append(0x00)          // 1: protocol_version = CASTV2_1_0
        Self.appendString(field: 2, sourceId, to: &out)
        Self.appendString(field: 3, destinationId, to: &out)
        Self.appendString(field: 4, namespace, to: &out)
        out.append(0x28); out.append(0x00)          // 5: payload_type = STRING
        Self.appendString(field: 6, payload, to: &out)
        return Data(out)
    }

    static func decode(_ data: Data) -> CastMessage? {
        let b = [UInt8](data)
        var i = 0
        var msg = CastMessage(sourceId: "", destinationId: "", namespace: "", payload: "")

        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while i < b.count {
            guard let key = varint() else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                i += 8
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return nil }
                let end = i + Int(len)
                let s = String(decoding: b[i..<end], as: UTF8.self)
                i = end
                switch field {
                case 2: msg.sourceId = s
                case 3: msg.destinationId = s
                case 4: msg.namespace = s
                case 6: msg.payload = s
                default: break
                }
            case 5:
                i += 4
            default:
                return nil
            }
        }
        return msg
    }

    private static func appendString(field: UInt8, _ s: String, to out: inout [UInt8]) {
        let bytes = Array(s.utf8)
        out.append((field << 3) | 2)
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(contentsOf: bytes)
    }

    private static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }
}
