import Foundation

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

struct Connection {
    let baseURL: URL
    let token: String
    let originalURL: URL

    init(_ text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, Self.isLocalHost(host) else {
            throw ClientError.message("请扫描电脑客户端的二维码，或粘贴同一 Wi-Fi 下的连接地址。")
        }
        let pieces = url.path.split(separator: "/")
        guard pieces.count == 2, pieces[0] == "connect", pieces[1].count >= 24,
              pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClientError.message("连接地址不完整，请重新扫描电脑上的二维码。")
        }
        token = String(pieces[1]); originalURL = url
        components.path = ""; components.query = nil; components.fragment = nil
        guard let base = components.url else { throw ClientError.message("连接地址不可用。") }
        baseURL = base
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".")
        let values = pieces.compactMap { Int($0) }
        guard pieces.count == 4, values.count == 4, values.allSatisfy({ 0...255 ~= $0 }) else { return false }
        return values[0] == 10 || values[0] == 127 || (values[0] == 192 && values[1] == 168)
            || (values[0] == 172 && 16...31 ~= values[1])
    }

    func resource(_ path: String, includeAccess: Bool = false) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port, url.scheme == baseURL.scheme else {
            throw ClientError.message("电脑返回了不属于当前连接的素材地址。")
        }
        if !includeAccess { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClientError.message("素材地址无效。") }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "access", value: token)]
        guard let result = components.url else { throw ClientError.message("素材地址无效。") }
        return result
    }
}

struct MediaItem: Decodable, Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let originalCover: Bool
    let preview: String
    let video: String
    let cover: String
}

struct MaterialGroup: Decodable, Identifiable {
    let id: String
    let title: String
    let videos: [MediaItem]
    let count: Int
}

struct LibraryReply: Decodable {
    let groups: [MaterialGroup]
    let totalVideos: Int
    let totalGroups: Int
    let batchTotal: Int
}

final class ComputerAPI: @unchecked Sendable {
    let connection: Connection
    private let session: URLSession
    init(_ connection: Connection) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 180
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }
    private func request(_ path: String) throws -> URLRequest {
        var request = URLRequest(url: try connection.resource(path))
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.message("未收到电脑的有效响应。") }
        if response.statusCode == 401 { throw ClientError.message("连接已失效，请扫描电脑端的新二维码。") }
        guard response.statusCode == 200 else { throw ClientError.message("素材暂时不可用，请在电脑检查后刷新。") }
    }
    func library(scope: String) async throws -> LibraryReply {
        let (data, response) = try await session.data(for: request("/api/library?scope=" + scope))
        try check(response)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LibraryReply.self, from: data)
    }
    func download(_ path: String, to destination: URL) async throws {
        let (temporary, response) = try await session.download(for: request(path))
        try check(response)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    func imageURL(_ path: String) -> URL? { try? connection.resource(path, includeAccess: true) }
}
