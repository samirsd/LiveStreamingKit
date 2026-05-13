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

public actor LiveStreamClient {
    private let config: LiveStreamConfig
    private let transport: HTTPTransport

    public init(config: LiveStreamConfig, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.config = config
        self.transport = transport
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
