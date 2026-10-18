import Foundation
import CryptoKit

/// Separate from the audio-only client: video is enabled only by an explicit
/// server capability and its media bytes never pass through the control API.
public actor LiveVideoHTTPClient {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let authToken: @Sendable () async -> String?
        public var requestTimeout: TimeInterval
        public var maximumAttempts: Int
        /// Only permits HTTP to localhost/127.0.0.1/::1, for an isolated test server.
        public var allowInsecureLoopback: Bool

        public init(baseURL: URL, authToken: @escaping @Sendable () async -> String?,
                    requestTimeout: TimeInterval = 10, maximumAttempts: Int = 3,
                    allowInsecureLoopback: Bool = false) {
            self.baseURL = baseURL
            self.authToken = authToken
            self.requestTimeout = requestTimeout
            self.maximumAttempts = max(1, min(5, maximumAttempts))
            self.allowInsecureLoopback = allowInsecureLoopback
        }
    }

    private let configuration: Configuration
    private let transport: any LiveVideoHTTPTransport

    public init(configuration: Configuration,
                transport: any LiveVideoHTTPTransport = LiveVideoURLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func isSupported() async throws -> Bool {
        let request = try request(path: "/api/v1/livestream/capabilities/", method: "GET")
        let data = try await perform(request)
        let value = try JSONDecoder().decode(Capabilities.self, from: data)
        return value.video.enabled && value.video.protocolName == "h264-aac-fmp4-v1"
            && value.video.delivery == "direct-upload-v1"
    }

    public func createSession(video: LiveVideoConfiguration, title: String? = nil,
                              recordingID: String? = nil) async throws -> LiveVideoHTTPSession {
        try video.validate()
        guard try await isSupported() else { throw LiveVideoHTTPError.unavailable }
        var request = try request(path: "/api/v1/livestream/sessions/", method: "POST")
        guard let token = await configuration.authToken(), !token.isEmpty else {
            throw LiveVideoHTTPError.notAuthenticated
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(CreateBody(
            multitrack_recording_id: recordingID, title: title,
            segment_duration_seconds: video.segmentDuration,
            sample_rate: Int(video.audioSampleRate), stereo_bitrate: video.audioBitrate,
            video_width: video.videoWidth, video_height: video.videoHeight,
            video_frame_rate: video.framesPerSecond, video_bitrate: video.videoBitrate
        ))
        // Creation is deliberately not retried without a server idempotency key.
        let value = try JSONDecoder().decode(CreateResponse.self, from: await perform(request))
        guard !value.id.isEmpty, !value.ingest_token.isEmpty,
              value.id.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").inverted) == nil else {
            throw LiveVideoHTTPError.invalidResponse
        }
        let authorizationURL = try resolve(value.upload_authorization_url, control: true)
        let expectedPath = "/api/v1/livestream/sessions/\(value.id)/uploads"
        guard authorizationURL.path == expectedPath else { throw LiveVideoHTTPError.unsafeURL }
        return LiveVideoHTTPSession(
            id: value.id, ingestToken: value.ingest_token,
            uploadAuthorizationURL: authorizationURL,
            listenerURL: try resolve(value.listener_url, control: false),
            masterPlaylistURL: try resolve(value.master_playlist_url, control: false)
        )
    }

    public nonisolated func sink(for session: LiveVideoHTTPSession) -> LiveVideoHTTPSink {
        LiveVideoHTTPSink(client: self, session: session)
    }

    public func endSession(_ session: LiveVideoHTTPSession) async throws {
        var request = try request(path: "/api/v1/livestream/sessions/\(session.id)/end/", method: "POST")
        request.setValue(session.ingestToken, forHTTPHeaderField: "X-Ingest-Token")
        // Match the existing end-session authentication policy.
        if let token = await configuration.authToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try await retry { try await self.perform(request) }
    }

    fileprivate func send(_ segment: LiveVideoSegment, session: LiveVideoHTTPSession) async throws {
        let isInitialization = segment.kind == .initialization
        guard !segment.data.isEmpty,
              segment.data.count <= (isInitialization ? 1_048_576 : 33_554_432),
              segment.sequence >= 0,
              isInitialization || (segment.duration.isFinite && segment.duration > 0 && segment.duration <= 15) else {
            throw LiveVideoHTTPError.invalidSegment
        }
        let checksum = SHA256.hash(data: segment.data).map { String(format: "%02x", $0) }.joined()
        let body = UploadBody(kind: isInitialization ? "initialization" : "segment",
                              sequence: isInitialization ? nil : segment.sequence,
                              bytes: segment.data.count, sha256: checksum,
                              duration: isInitialization ? nil : segment.duration,
                              is_final: isInitialization ? nil : false)
        let encoded = try JSONEncoder().encode(body)
        try await retry {
            try Task.checkCancellation()
            var authorization = try self.request(url: session.uploadAuthorizationURL, method: "POST", control: true)
            authorization.setValue(session.ingestToken, forHTTPHeaderField: "X-Ingest-Token")
            authorization.httpBody = encoded
            let grant = try JSONDecoder().decode(UploadGrant.self, from: await self.perform(authorization))
            guard grant.method == "PUT", !grant.upload_id.isEmpty else { throw LiveVideoHTTPError.invalidResponse }
            let uploadURL = try self.resolve(grant.upload_url, control: false)
            let commitURL = try self.resolve(grant.commit_url, control: true)
            guard commitURL.path.hasPrefix(session.uploadAuthorizationURL.path + "/"),
                  commitURL.path.hasSuffix("/commit") else { throw LiveVideoHTTPError.unsafeURL }
            var upload = try self.request(url: uploadURL, method: "PUT", control: false)
            upload.allHTTPHeaderFields = [:]
            for (name, value) in grant.headers {
                guard !["authorization", "cookie", "x-ingest-token", "host"].contains(name.lowercased()) else {
                    throw LiveVideoHTTPError.invalidResponse
                }
                upload.setValue(value, forHTTPHeaderField: name)
            }
            upload.httpBody = segment.data
            let (_, response) = try await self.transport.perform(upload)
            // A lost commit acknowledgement can cause another immutable PUT.
            // Its precondition failure must still be reconciled by the server.
            if response.statusCode != 412 {
                if response.statusCode == 403 { throw LiveVideoHTTPError.expiredUpload }
                try self.ensureSuccess(response)
            }
            var commit = try self.request(url: commitURL, method: "POST", control: true)
            commit.setValue(session.ingestToken, forHTTPHeaderField: "X-Ingest-Token")
            commit.httpBody = Data("{}".utf8)
            _ = try await self.perform(commit)
        }
    }

    private func request(path: String, method: String) throws -> URLRequest {
        try request(url: resolve(path, control: true), method: method, control: true)
    }

    private func request(url: URL, method: String, control: Bool) throws -> URLRequest {
        _ = try resolve(url.absoluteString, control: control)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func resolve(_ value: String, control: Bool) throws -> URL {
        guard let url = URL(string: value, relativeTo: configuration.baseURL)?.absoluteURL,
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty else { throw LiveVideoHTTPError.unsafeURL }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard url.scheme?.lowercased() == "https"
                || (configuration.allowInsecureLoopback && loopback && url.scheme == "http") else {
            throw LiveVideoHTTPError.unsafeURL
        }
        if control {
            guard url.scheme?.lowercased() == configuration.baseURL.scheme?.lowercased(),
                  host.lowercased() == configuration.baseURL.host?.lowercased(),
                  url.port == configuration.baseURL.port else { throw LiveVideoHTTPError.unsafeURL }
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await transport.perform(request)
        try ensureSuccess(response)
        return data
    }

    private func ensureSuccess(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw LiveVideoHTTPError.notAuthenticated }
            throw LiveVideoHTTPError.rejected(statusCode: response.statusCode)
        }
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0..<configuration.maximumAttempts {
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard attempt + 1 < configuration.maximumAttempts, Self.canRetry(error) else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
            }
        }
        throw LiveVideoHTTPError.invalidResponse
    }

    private static func canRetry(_ error: Error) -> Bool {
        if let error = error as? LiveVideoHTTPError {
            switch error {
            case .expiredUpload: return true
            case .rejected(let status): return status == 429 || (500...599).contains(status)
            default: return false
            }
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}

public struct LiveVideoHTTPSession: Sendable, Equatable {
    public let id: String
    public let ingestToken: String
    public let uploadAuthorizationURL: URL
    public let listenerURL: URL
    public let masterPlaylistURL: URL
}

public struct LiveVideoHTTPSink: LiveVideoSegmentSink {
    private let client: LiveVideoHTTPClient
    private let session: LiveVideoHTTPSession
    fileprivate init(client: LiveVideoHTTPClient, session: LiveVideoHTTPSession) {
        self.client = client
        self.session = session
    }
    public func send(_ segment: LiveVideoSegment) async throws { try await client.send(segment, session: session) }
    public func finish() async throws { try await client.endSession(session) }
}

public enum LiveVideoHTTPError: Error, Sendable, Equatable, LocalizedError {
    case unavailable, notAuthenticated, invalidResponse, unsafeURL, invalidSegment, expiredUpload
    case rejected(statusCode: Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Video broadcasting is not enabled on this server. Audio broadcasting is still available."
        case .notAuthenticated: "Sign in again before broadcasting."
        case .invalidResponse: "The streaming server returned an unsupported response."
        case .unsafeURL: "The streaming server returned an unsafe media address."
        case .invalidSegment: "A video segment could not be uploaded. The local recording was retained."
        case .expiredUpload: "The video upload permission expired."
        case .rejected(let status): "The streaming server rejected this request (\(status))."
        }
    }
}

public protocol LiveVideoHTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// No cookies, persistent cache or redirects that could forward ingest secrets.
public final class LiveVideoURLSessionTransport: LiveVideoHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: VideoNoRedirectDelegate(), delegateQueue: nil)
    }
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LiveVideoHTTPError.invalidResponse }
        return (data, response)
    }
    deinit { session.invalidateAndCancel() }
}

private final class VideoNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct Capabilities: Decodable {
    struct Video: Decodable {
        let enabled: Bool
        let protocolName: String?
        let delivery: String?
        enum CodingKeys: String, CodingKey { case enabled, protocolName = "protocol", delivery }
    }
    let video: Video
}
private struct CreateBody: Encodable {
    let multitrack_recording_id: String?
    let title: String?
    let segment_duration_seconds: Double
    let sample_rate: Int
    let stereo_bitrate: Int
    let video_width: Int
    let video_height: Int
    let video_frame_rate: Int
    let video_bitrate: Int
    let codec = "h264-aac-fmp4"
}
private struct CreateResponse: Decodable {
    let id: String
    let ingest_token: String
    let upload_authorization_url: String
    let listener_url: String
    let master_playlist_url: String
}
private struct UploadBody: Encodable {
    let kind: String
    let sequence: Int?
    let bytes: Int
    let sha256: String
    let duration: TimeInterval?
    let is_final: Bool?
}
private struct UploadGrant: Decodable {
    let upload_id: String
    let upload_url: String
    let method: String
    let headers: [String: String]
    let commit_url: String
}
