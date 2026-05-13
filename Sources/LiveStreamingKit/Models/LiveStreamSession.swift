import Foundation

public struct LiveStreamSession: Sendable, Equatable, Codable {
    public let id: String
    public let ingestToken: String
    public let ingestURL: URL
    public let listenerURL: URL
    public let masterPlaylistURL: URL
    public let createdAt: Date

    public init(
        id: String,
        ingestToken: String,
        ingestURL: URL,
        listenerURL: URL,
        masterPlaylistURL: URL,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.ingestToken = ingestToken
        self.ingestURL = ingestURL
        self.listenerURL = listenerURL
        self.masterPlaylistURL = masterPlaylistURL
        self.createdAt = createdAt
    }
}
