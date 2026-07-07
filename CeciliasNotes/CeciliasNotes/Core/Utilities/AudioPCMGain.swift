import AVFoundation

/// Software input boost — Mac has no `AVAudioSession` voice-processing
/// pipeline, so quiet mics need a gain stage before encode + recognition.
enum AudioPCMGain {
    /// Tunable via UserDefaults for field testing without a rebuild.
    static var macRecordingGain: Float {
        let stored = UserDefaults.standard.object(forKey: "ceciliasnotes.audio.macGain") as? Float
        return stored ?? 2.75
    }

    /// Returns a deep copy with float samples scaled and clamped to ±1.
    static func boostedCopy(of buffer: AVAudioPCMBuffer, gain: Float = macRecordingGain) -> AVAudioPCMBuffer? {
        guard gain > 1.001 else { return buffer.deepCopy() }
        guard let copy = buffer.deepCopy(),
              let channelData = copy.floatChannelData else { return buffer.deepCopy() }
        let frames = Int(copy.frameLength)
        let channels = Int(copy.format.channelCount)
        for ch in 0..<channels {
            let data = channelData[ch]
            for i in 0..<frames {
                data[i] = min(1, max(-1, data[i] * gain))
            }
        }
        return copy
    }
}

extension AVAudioPCMBuffer {
    /// Deep-copy float channel data so the engine can recycle the tap buffer.
    nonisolated func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else { return nil }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        let byteCount = Int(frameLength) * MemoryLayout<Float>.size
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], byteCount)
            }
        }
        return copy
    }
}
