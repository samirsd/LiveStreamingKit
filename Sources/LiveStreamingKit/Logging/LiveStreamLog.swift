import Foundation
import os

/// Categorized `os.Logger` instances for the live stream kit.
///
/// Why a small enum here instead of one shared logger:
/// - Console.app + `log stream --predicate 'subsystem == "carnyx.livestream"'`
///   filters by category, so splitting by subsystem makes ad-hoc debugging
///   much easier than a single torrent.
/// - Each category corresponds to a layer of the pipeline, so when something
///   silently fails (which has happened) the user can ask "is this an engine
///   problem, a network problem, or an upload-queue problem?" and find out
///   in seconds.
///
/// Usage:
///     LiveStreamLog.engine.info("start requested")
///     LiveStreamLog.client.error("createSession failed: \(error)")
public enum LiveStreamLog {
    public static let subsystem = "carnyx.livestream"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let client = Logger(subsystem: subsystem, category: "client")
    public static let uploader = Logger(subsystem: subsystem, category: "uploader")
    public static let social = Logger(subsystem: subsystem, category: "social")
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
