import AVFoundation
import Foundation

public final class AudioCaptureEngine: NSObject, @unchecked Sendable {
    public static let shared = AudioCaptureEngine()
    
    private let audioEngine = AVAudioEngine()
    private var isRecording = false
    private let targetSampleRate: Double = 16000.0
    
    public var onAudioBufferReceived: (([Float]) -> Void)?
    public var onLevelMeterUpdated: ((Float) -> Void)?
    
    public override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }
    
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        if isRecording {
            stopCapture()
            try? startCapture()
        }
    }
    
    public func startCapture() throws {
        guard !isRecording else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "PearlVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio hardware input format unavailable."])
        }
        
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        
        let formatConverter = AVAudioConverter(from: inputFormat, to: recordingFormat)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            
            // Measure RMS level for 60 Hz waveform metering
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            if let data = channelData, frameLength > 0 {
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += data[i] * data[i]
                }
                let rms = sqrt(sum / Float(frameLength))
                let normalized = min(1.0, max(0.05, rms * 5.0))
                DispatchQueue.main.async {
                    self.onLevelMeterUpdated?(normalized)
                }
            }
            
            // Convert to 16kHz PCM Float
            if let converter = formatConverter {
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate) + 100
                )!
                
                var error: NSError?
                var isFinished = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if isFinished {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    isFinished = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                if let floatData = convertedBuffer.floatChannelData?[0] {
                    let floatArray = Array(UnsafeBufferPointer(start: floatData, count: Int(convertedBuffer.frameLength)))
                    self.onAudioBufferReceived?(floatArray)
                }
            }
        }
        
        try audioEngine.start()
        isRecording = true
    }
    
    public func stopCapture() {
        guard isRecording else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false
    }
    
    public var active: Bool {
        return isRecording
    }
}
