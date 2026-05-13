import Foundation
import AVFoundation

public protocol AudioBufferObserver: AnyObject, Sendable {
    func observe(buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition)
}

public struct AudioBufferFanout: Sendable {
    private let storage = ObserverStorage()

    public init() {}

    public func add(_ observer: AudioBufferObserver) {
        storage.add(observer)
    }

    public func remove(_ observer: AudioBufferObserver) {
        storage.remove(observer)
    }

    public func notify(buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        storage.forEach { $0.observe(buffer: buffer, at: sampleTime) }
    }

    public var isEmpty: Bool { storage.isEmpty }

    private final class ObserverStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [WeakBox] = []

        func add(_ observer: AudioBufferObserver) {
            lock.lock(); defer { lock.unlock() }
            observers.removeAll { $0.value == nil }
            observers.append(WeakBox(value: observer))
        }

        func remove(_ observer: AudioBufferObserver) {
            lock.lock(); defer { lock.unlock() }
            observers.removeAll { $0.value == nil || $0.value === observer }
        }

        func forEach(_ body: (AudioBufferObserver) -> Void) {
            lock.lock()
            let snapshot = observers.compactMap(\.value)
            lock.unlock()
            for observer in snapshot { body(observer) }
        }

        var isEmpty: Bool {
            lock.lock(); defer { lock.unlock() }
            return observers.allSatisfy { $0.value == nil }
        }

        private struct WeakBox {
            weak var value: AudioBufferObserver?
        }
    }
}
