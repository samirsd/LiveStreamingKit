@preconcurrency import AVFoundation
import XCTest
@testable import LiveStreamingVideo

final class LiveVideoFrameRendererTests: XCTestCase {
    func testLandscapeCameraIsCenterCroppedWithoutTurningImageSidewaysAndKeepsTiming() throws {
        let source = try sample(width: 1280, height: 720)
        let result = try LiveVideoFrameRenderer().render(source)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(result))
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 720)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 1280)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), CMTime(value: 42, timescale: 30))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        // The landscape frame's outer blue quarters must be cropped away.
        for (x, y) in [(4, 4), (715, 1275), (360, 640)] {
            let pixel = bytes.advanced(by: y * stride + x * 4)
            XCTAssertGreaterThan(pixel[2], 240)
            XCTAssertLessThan(pixel[0], 10)
        }
    }

    func testPortraitCameraKeepsItsWholeFrameAndInvalidCanvasFails() throws {
        let source = try sample(width: 720, height: 1280)
        let result = try LiveVideoFrameRenderer().render(source)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(result))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[0], 240) // Left blue edge is retained.
        XCTAssertThrowsError(try LiveVideoFrameRenderer(width: 719, height: 1280))
    }

    private func sample(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes.advanced(by: y * CVPixelBufferGetBytesPerRow(image) + x * 4)
                let outer = x < width / 4 || x >= width * 3 / 4
                pixel[0] = outer ? 255 : 0; pixel[1] = 0; pixel[2] = outer ? 0 : 255; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                                   formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: 42, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let description = try XCTUnwrap(format)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                                                               formatDescription: description, sampleTiming: &timing,
                                                               sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
