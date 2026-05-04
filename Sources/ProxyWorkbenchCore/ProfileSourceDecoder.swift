import Foundation

public enum ProfileSourceDecoder {
    public static func decodedText(from data: Data) throws -> String {
        guard data.count <= 8 * 1024 * 1024 else {
            throw ProfileSourceDecoderError.sourceTooLarge
        }

        guard let text = string(from: data) else {
            throw ProfileSourceDecoderError.unsupportedEncoding
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeProfile(trimmed) {
            return text
        }

        if let decoded = base64DecodedProfile(from: trimmed) {
            return decoded
        }

        return text
    }

    private static func string(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return nil
    }

    private static func base64DecodedProfile(from text: String) -> String? {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !compact.isEmpty else { return nil }

        let padded = compact.padding(toLength: compact.count + (4 - compact.count % 4) % 4, withPad: "=", startingAt: 0)
        guard let decodedData = Data(base64Encoded: padded),
              let decoded = string(from: decodedData),
              looksLikeProfile(decoded)
        else {
            return nil
        }
        return decoded
    }

    private static func looksLikeProfile(_ text: String) -> Bool {
        text.contains("[Proxy]") || text.contains("[General]") || text.contains("[Proxy Group]") || text.contains("[Rule]")
    }
}

public enum ProfileSourceDecoderError: Error, CustomStringConvertible, Sendable {
    case sourceTooLarge
    case unsupportedEncoding

    public var description: String {
        switch self {
        case .sourceTooLarge:
            "Profile source exceeds 8 MiB"
        case .unsupportedEncoding:
            "Profile source is not UTF-8 or Latin-1 text"
        }
    }
}
