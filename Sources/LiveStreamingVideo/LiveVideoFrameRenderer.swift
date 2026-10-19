@preconcurrency import AVFoundation
import CoreImage

/// Renders the selected camera into an exact portrait canvas. Landscape cameras
/// are center-cropped, rather than rotating a person's image sideways. A camera
/// mounted vertically should first apply its explicit capture rotation.
public final class LiveVideoFrameRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool
    public let width: Int
    public let height: Int

    public init(width: Int = 720, height: Int = 1280) throws {
        guard width > 0, height > 0, width <= 3840, height <= 3840,
              width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw LiveVideoError.invalidConfiguration("Invalid video canvas dimensions")
        }
        self.width = width
        self.height = height
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw LiveVideoError.encodingFailed("Cannot allocate the video canvas") }
        self.pool = pool
    }

    /// Called on the camera's serial output queue, never the audio tap. Preserves
    /// source timing; the broadcaster still receives its separate host-clock PTS.
    public func render(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        try lock.withLock {
            guard let source = CMSampleBufferGetImageBuffer(sample) else {
                throw LiveVideoError.invalidSample("The camera supplied no image")
            }
            var pixels: CVPixelBuffer?
            let allocation: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 16]
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocation as CFDictionary, &pixels) == kCVReturnSuccess,
                  let pixels else { throw LiveVideoError.encodingFailed("The video encoder cannot keep up with the camera") }
            let image = CIImage(cvPixelBuffer: source)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { throw LiveVideoError.invalidSample("Empty camera image") }
            let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
            let rendered = image
                .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: .init(scaleX: scale, y: scale))
                .transformed(by: .init(translationX: (CGFloat(width) - extent.width * scale) / 2,
                                       y: (CGFloat(height) - extent.height * scale) / 2))
            context.render(rendered, to: pixels, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                               formatDescriptionOut: &description) == noErr,
                  let description else { throw LiveVideoError.invalidSample("Cannot describe the portrait frame") }
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else {
                throw LiveVideoError.invalidSample("The camera frame has no timing")
            }
            var output: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                            formatDescription: description, sampleTiming: &timing,
                                                            sampleBufferOut: &output) == noErr,
                  let output else { throw LiveVideoError.invalidSample("Cannot create the portrait frame") }
            return output
        }
    }
}
