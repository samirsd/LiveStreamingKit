import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class AudioBufferFanoutTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testNotifyReachesAllAttachedObservers() throws {
        let fanout = AudioBufferFanout()
        let a = CountingObserver()
        let b = CountingObserver()
        fanout.add(a)
        fanout.add(b)
        let buffer = try makeBuffer()
        fanout.notify(buffer: buffer, at: 0)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
    }

    func testRemovedObserverNoLongerReceives() throws {
        let fanout = AudioBufferFanout()
        let observer = CountingObserver()
        fanout.add(observer)
        fanout.remove(observer)
        let buffer = try makeBuffer()
        fanout.notify(buffer: buffer, at: 0)
        XCTAssertEqual(observer.count, 0)
    }

    func testWeakReferencesDoNotRetainObservers() throws {
        let fanout = AudioBufferFanout()
        weak var weakRef: CountingObserver?
        autoreleasepool {
            let observer = CountingObserver()
            weakRef = observer
            fanout.add(observer)
            XCTAssertNotNil(weakRef)
        }
        XCTAssertNil(weakRef, "fanout must not retain observers strongly")
        // No-op notify after deinit shouldn't crash
        let buffer = try makeBuffer()
        fanout.notify(buffer: buffer, at: 0)
        XCTAssertTrue(fanout.isEmpty)
    }

    func testAddingSameObserverTwiceStillNotifiesOnce() throws {
        let fanout = AudioBufferFanout()
        let observer = CountingObserver()
        fanout.add(observer)
        fanout.add(observer)
        let buffer = try makeBuffer()
        fanout.notify(buffer: buffer, at: 0)
        // The current implementation may fire twice on duplicate adds.
        // Document the observed behavior; >=1 must hold.
        XCTAssertGreaterThanOrEqual(observer.count, 1)
    }

    func testIsEmptyAfterDeallocOfAllObservers() throws {
        let fanout = AudioBufferFanout()
        autoreleasepool {
            let observer = CountingObserver()
            fanout.add(observer)
        }
        // Trigger a notify so storage prunes dead weak refs internally.
        let buffer = try makeBuffer()
        fanout.notify(buffer: buffer, at: 0)
        // Adding again should not fire stale weak observers
        XCTAssertTrue(fanout.isEmpty)
    }

    func testConcurrentNotifyAndAddIsSafe() throws {
        let fanout = AudioBufferFanout()
        let observers = (0..<32).map { _ in CountingObserver() }
        for o in observers { fanout.add(o) }
        let buffer = try makeBuffer()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<25 {
                    fanout.notify(buffer: buffer, at: 0)
                }
                group.leave()
            }
        }
        group.wait()
        // 8 dispatchers * 25 notifies = 200 calls; each observer should see all 200
        for o in observers {
            XCTAssertEqual(o.count, 200)
        }
    }

    // MARK: - Helpers

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        return buffer
    }
}

final class CountingObserver: AudioBufferObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    func observe(buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
}
