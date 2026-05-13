import Foundation

public enum ADTSFraming {
    public static let headerByteCount: Int = 7

    public static func samplingFrequencyIndex(for sampleRate: Double) -> UInt8? {
        switch Int(sampleRate.rounded()) {
        case 96_000: return 0
        case 88_200: return 1
        case 64_000: return 2
        case 48_000: return 3
        case 44_100: return 4
        case 32_000: return 5
        case 24_000: return 6
        case 22_050: return 7
        case 16_000: return 8
        case 12_000: return 9
        case 11_025: return 10
        case  8_000: return 11
        case  7_350: return 12
        default: return nil
        }
    }

    public static func header(
        rawAACFrameSize: Int,
        sampleRate: Double,
        channelCount: Int,
        profile: UInt8 = 2 // AAC-LC
    ) -> Data? {
        guard let frequencyIndex = samplingFrequencyIndex(for: sampleRate) else { return nil }
        let frameLength = rawAACFrameSize + headerByteCount
        guard frameLength < (1 << 13) else { return nil }
        guard channelCount > 0, channelCount <= 7 else { return nil }
        let channelConfig = UInt8(channelCount)
        // Profile bits in ADTS = audio object type - 1
        let profileBits = profile - 1

        var bytes = [UInt8](repeating: 0, count: headerByteCount)
        bytes[0] = 0xFF
        bytes[1] = 0xF1 // sync + version 0 (MPEG-4) + layer 00 + protection absent
        bytes[2] = ((profileBits & 0x3) << 6)
            | ((frequencyIndex & 0xF) << 2)
            | ((channelConfig >> 2) & 0x1)
        bytes[3] = ((channelConfig & 0x3) << 6)
            | UInt8((frameLength >> 11) & 0x3)
        bytes[4] = UInt8((frameLength >> 3) & 0xFF)
        bytes[5] = UInt8((frameLength & 0x7) << 5) | 0x1F
        bytes[6] = 0xFC
        return Data(bytes)
    }

    public static func wrap(_ packet: EncodedAACPacket, channelCount: Int) -> Data? {
        guard let header = header(
            rawAACFrameSize: packet.data.count,
            sampleRate: packet.sampleRate,
            channelCount: channelCount
        ) else { return nil }
        var data = Data(capacity: header.count + packet.data.count)
        data.append(header)
        data.append(packet.data)
        return data
    }
}
