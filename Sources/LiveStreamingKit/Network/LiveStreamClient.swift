import Foundation

public struct CreateSessionRequest: Codable, Sendable {
    public let multitrack_recording_id: String?
    public let title: String?
    public let segment_duration_seconds: Double
    public let sample_rate: Int
    public let stereo_bitrate: Int
    public let codec: String

    public init(
        multitrackRecordingID: String?,
        title: String?,
        segmentDuration: Double,
        sampleRate: Int,
        stereoBitrate: Int,
        codec: String = "aac-lc-adts"
    ) {
        self.multitrack_recording_id = multitrackRecordingID
        self.title = title
        self.segment_duration_seconds = segmentDuration
        self.sample_rate = sampleRate
        self.stereo_bitrate = stereoBitrate
        self.codec = codec
    }
}

public struct CreateSessionResponse: Codable, Sendable {
    public let id: String
    public let ingest_token: String
    public let ingest_url: String
    public let listener_url: String
    public let master_playlist_url: String
}

/// Subset of the session-status response we poll for during a broadcast.
///
/// The backend's full response includes more fields (codec, ingest token,
/// playlist URLs, etc.) but the social loop only cares about the engagement
/// counters. Decoding just these keeps us forward-compatible with any new
/// fields the server adds.
public struct SessionStatusResponse: Codable, Sendable {
    public let status: String
    public let listener_count: Int?
    public let total_listeners: Int?
    public let peak_listener_count: Int?
    public let reaction_totals: [String: Int]?
}

public struct ReactionsResponse: Codable, Sendable {
    public let reactions: [ReactionDTO]
    public let totals: [String: Int]
}

public struct ReactionDTO: Codable, Sendable {
    public let id: String
    public let type: String
    public let ts: TimeInterval
}

public actor LiveStreamClient {
    private let config: LiveStreamConfig
    private let transport: HTTPTransport

    public init(config: LiveStreamConfig, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.config = config
        self.transport = transport
    }

    /// The base URL this client targets. Exposed for listener-side
    /// consumers that need to resolve relative paths (master playlist, OG
    /// image, etc.) against the same host. Use `nonisolated` since `config`
    /// is immutable after init.
    public nonisolated var baseURL: URL {
        config.ingestBaseURL
    }

    public func createSession() async throws -> LiveStreamSession {
        let request = try await buildJSONRequest(
            path: "/api/v1/livestream/sessions/",
            method: "POST",
            body: CreateSessionRequest(
                multitrackRecordingID: config.multitrackRecordingID,
                title: config.title,
                segmentDuration: config.segmentDuration,
                sampleRate: Int(config.sampleRate),
                stereoBitrate: config.stereoBitrate
            )
        )
        let (data, response) = try await transport.perform(request)
        try ensureSuccess(response, data: data)
        let decoded = try JSONDecoder.iso8601().decode(CreateSessionResponse.self, from: data)
        return LiveStreamSession(
            id: decoded.id,
            ingestToken: decoded.ingest_token,
            ingestURL: try url(decoded.ingest_url),
            listenerURL: try url(decoded.listener_url),
            masterPlaylistURL: try url(decoded.master_playlist_url)
        )
    }

    public func uploadSegment(
        session: LiveStreamSession,
        segment: HLSSegment
    ) async throws {
        let path = "/api/v1/livestream/sessions/\(session.id)/segments/\(segment.sequence)/"
        var request = try await buildRequest(path: path, method: "PUT")
        request.setValue("audio/aac", forHTTPHeaderField: "Content-Type")
        request.setValue(session.ingestToken, forHTTPHeaderField: "X-Ingest-Token")
        request.setValue(String(format: "%.3f", segment.duration), forHTTPHeaderField: "X-Segment-Duration")
        if segment.isFinalSegment {
            request.setValue("true", forHTTPHeaderField: "X-Segment-Final")
        }
        request.httpBody = segment.data
        let (data, response) = try await transport.perform(request)
        try ensureSuccess(response, data: data)
    }

    public func endSession(_ session: LiveStreamSession) async throws {
        let path = "/api/v1/livestream/sessions/\(session.id)/end/"
        var request = try await buildRequest(path: path, method: "POST")
        request.setValue(session.ingestToken, forHTTPHeaderField: "X-Ingest-Token")
        let (data, response) = try await transport.perform(request)
        try ensureSuccess(response, data: data)
    }

    /// Poll the session-status endpoint for engagement counters. The endpoint
    /// is `AllowAny` on the backend so this skips the bearer token to keep
    /// the social poller alive even if the broadcaster's auth has expired
    /// mid-set (the rest of the engine relies on `X-Ingest-Token` for that
    /// reason). Returns `nil` on network failure rather than throwing —
    /// engagement polling is best-effort.
    public func fetchSessionStatus(_ session: LiveStreamSession) async -> SessionStatusResponse? {
        let path = "/api/v1/livestream/sessions/\(session.id)/"
        guard let url = URL(string: path, relativeTo: config.ingestBaseURL)?.absoluteURL else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.perform(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return try JSONDecoder().decode(SessionStatusResponse.self, from: data)
        } catch {
            return nil
        }
    }

    /// Fire a single reaction against a live session. Anonymous on the
    /// backend — no auth header is sent. Returns the server-acknowledged
    /// record on success, or `nil` on any failure (network, decode, or
    /// rejection). UI callers typically render an optimistic floating emoji
    /// before awaiting this, so a transient failure is recoverable.
    public func postReaction(
        _ session: LiveStreamSession,
        type: String
    ) async -> LiveReactionEvent? {
        let path = "/api/v1/livestream/sessions/\(session.id)/reactions/"
        guard let url = URL(string: path, relativeTo: config.ingestBaseURL)?.absoluteURL else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["type": type])
        do {
            let (data, response) = try await transport.perform(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            let dto = try JSONDecoder().decode(ReactionDTO.self, from: data)
            return LiveReactionEvent(id: dto.id, type: dto.type, ts: dto.ts)
        } catch {
            return nil
        }
    }

    /// Poll the reactions feed for events newer than `since`. Pass `nil` for
    /// the initial fetch (the backend returns its default lookback window).
    /// Like `fetchSessionStatus`, this is best-effort: returns an empty
    /// response on any failure so the poller stays alive across transient
    /// network blips.
    public func fetchReactions(
        _ session: LiveStreamSession,
        since: TimeInterval? = nil
    ) async -> ReactionsResponse? {
        var path = "/api/v1/livestream/sessions/\(session.id)/reactions/"
        if let since {
            // `since` ts is a UNIX double; URL-encode just to be safe.
            let value = "\(since)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(since)"
            path += "?since=\(value)"
        }
        guard let url = URL(string: path, relativeTo: config.ingestBaseURL)?.absoluteURL else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.perform(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return try JSONDecoder().decode(ReactionsResponse.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func buildRequest(path: String, method: String) async throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.ingestBaseURL)?.absoluteURL else {
            throw LiveStreamError.invalidConfiguration("malformed ingest URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = await config.authTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw LiveStreamError.notAuthenticated
        }
        return request
    }

    private func buildJSONRequest(path: String, method: String, body: Encodable) async throws -> URLRequest {
        var request = try await buildRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        return request
    }

    private func ensureSuccess(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LiveStreamError.notAuthenticated
        case let code:
            let body = String(data: data, encoding: .utf8)
            throw LiveStreamError.backendRejected(statusCode: code, body: body)
        }
    }

    private func url(_ string: String) throws -> URL {
        if let absolute = URL(string: string), absolute.scheme != nil {
            return absolute
        }
        guard let resolved = URL(string: string, relativeTo: config.ingestBaseURL)?.absoluteURL else {
            throw LiveStreamError.invalidConfiguration("malformed url: \(string)")
        }
        return resolved
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
