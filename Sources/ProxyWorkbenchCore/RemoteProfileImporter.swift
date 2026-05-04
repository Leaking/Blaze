import Foundation

public enum RemoteProfileImporter {
    public static func importText(from url: URL) async throws -> String {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw RemoteProfileImporterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ProxyWorkbench/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw RemoteProfileImporterError.httpStatus(http.statusCode)
        }

        return try ProfileSourceDecoder.decodedText(from: data)
    }
}

public enum RemoteProfileImporterError: Error, CustomStringConvertible, Sendable {
    case invalidURL
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .invalidURL:
            "Enter an http or https URL"
        case .httpStatus(let code):
            "Remote server returned HTTP \(code)"
        }
    }
}
