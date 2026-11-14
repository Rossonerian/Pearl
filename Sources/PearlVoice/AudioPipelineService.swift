import AVFoundation
import Foundation
import Speech

/// Unified single-engine audio pipeline for Pearl.
///
/// Consolidates audio input processing onto a single `AVAudioEngine` tap, eliminating
/// duplicated hardware taps and resource contention. Feeds both live speech recognition
/// (`SFSpeechAudioBufferRecognitionRequest`) and RMS audio power metering (for 60 Hz HUD animations),
/// while concurrently downsampling to 16 kHz mono Float samples for barge-in detection
/// and Push-To-Talk buffers.
///
/// Ensures clean deallocation and resource release when entering standby to maintain
/// the resident idle physical footprint <= 30 MB.
public final class AudioPipelineService: NSObject, @unchecked Sendable {
    public static let shared = AudioPipelineService()
    
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var isEngineRunning: Bool = false
    private var isCaptureActive: Bool = false
    private var activeSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    
    private let targetSampleRate: Double = 16000.0
    private var formatConverter: AVAudioConverter?
    private var recordingFormat: AVAudioFormat?
    
    // Callbacks
    public var onAudioBufferReceived: (([Float]) -> Void)?
    public var onLevelMeterUpdated: ((Float) -> Void)?
    
    public override init() {
        super.init()
    }
    
    // MARK: - Engine Lifecycle Management
    
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        lock.lock()
        defer { lock.unlock() }
        
        guard isEngineRunning else { return }
        NSLog("[PearlVoice] Audio engine configuration change detected; restarting pipeline...")
        tearDownEngineUnderLock()
        do {
            try setupAndStartEngineUnderLock()
        } catch {
            NSLog("[PearlVoice] Failed to restart audio pipeline after config change: %@", error.localizedDescription)
        }
    }
    
    private func setupAndStartEngineUnderLock() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioPipelineService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone hardware or audio input format unavailable."]
            )
        }
        
        guard let pcmRecordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioPipelineService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create 16kHz PCM audio format."]
            )
        }
        
        self.recordingFormat = pcmRecordingFormat
        self.formatConverter = AVAudioConverter(from: inputFormat, to: pcmRecordingFormat)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        
        // Single unified tap on bus 0 with 1024-frame buffer
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            self.processIncomingBuffer(buffer, inputFormat: inputFormat)
        }
        
        engine.prepare()
        try engine.start()
        
        self.audioEngine = engine
        self.isEngineRunning = true
        NSLog("[PearlVoice] Unified audio engine started (input rate: %.0f Hz, channels: %d)", inputFormat.sampleRate, inputFormat.channelCount)
    }
    
    private func tearDownEngineUnderLock() {
        if let engine = audioEngine {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        
        audioEngine = nil
        formatConverter = nil
        recordingFormat = nil
        isEngineRunning = false
    }
    
    // MARK: - Buffer Processing Pipeline
    
    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        // 1. Calculate RMS audio level for 60 Hz waveform HUD animation
        if let channelData = buffer.floatChannelData?[0] {
            let frameLength = Int(buffer.frameLength)
            if frameLength > 0 {
                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = channelData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameLength))
                let normalized = min(1.0, max(0.05, rms * 5.0))
                DispatchQueue.main.async { [weak self] in
                    self?.onLevelMeterUpdated?(normalized)
                }
            }
        }
        
        // 2. Feed active Speech Recognition request directly with raw buffer
        lock.lock()
        let speechReq = self.activeSpeechRequest
        let captureActive = self.isCaptureActive
        let converter = self.formatConverter
        let recFormat = self.recordingFormat
        lock.unlock()
        
        if let speechReq = speechReq {
            speechReq.append(buffer)
        }
        
        // 3. Convert to 16kHz PCM Float for barge-in detection and capture subscribers
        guard captureActive || BargeInController.shared.onBargeInTriggered != nil || onAudioBufferReceived != nil else {
            return
        }
        
        guard let converter = converter, let recFormat = recFormat else { return }
        
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * targetSampleRate / inputFormat.sampleRate) + 100
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recFormat, frameCapacity: frameCapacity) else {
            return
        }
        
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
            let sampleCount = Int(convertedBuffer.frameLength)
            if sampleCount > 0 {
                let floatArray = Array(UnsafeBufferPointer(start: floatData, count: sampleCount))
                
                // Real-time barge-in acoustic monitor
                BargeInController.shared.handleAudioFrame(samples: floatArray)
                
                // Subscribers (e.g. PushToTalkController)
                if captureActive {
                    onAudioBufferReceived?(floatArray)
                }
            }
        }
    }
    
    // MARK: - Speech Recognition Consumer Binding
    
    public func attachSpeechRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        
        self.activeSpeechRequest = request
        if !isEngineRunning {
            try setupAndStartEngineUnderLock()
        }
    }
    
    public func detachSpeechRecognitionRequest() {
        lock.lock()
        defer { lock.unlock() }
        
        self.activeSpeechRequest = nil
        
        // If capture is also inactive, enter standby to release hardware resources
        if !isCaptureActive {
            tearDownEngineUnderLock()
            NSLog("[PearlVoice] Audio pipeline entered standby (recognition detached). Memory released.")
        }
    }
    
    // MARK: - Audio Capture Consumer Binding
    
    public func startCapture() throws {
        lock.lock()
        defer { lock.unlock() }
        
        self.isCaptureActive = true
        if !isEngineRunning {
            try setupAndStartEngineUnderLock()
        }
    }
    
    public func stopCapture() {
        lock.lock()
        defer { lock.unlock() }
        
        self.isCaptureActive = false
        
        // If speech recognition is also inactive, enter standby
        if activeSpeechRequest == nil {
            tearDownEngineUnderLock()
            NSLog("[PearlVoice] Audio pipeline entered standby (capture stopped). Memory released.")
        }
    }
    
    // MARK: - Standby & Resource Release
    
    /// Tears down the audio engine, tap, and format converters completely,
    /// closing hardware streams and maintaining idle physical footprint <= 30 MB.
    public func enterStandby() {
        lock.lock()
        defer { lock.unlock() }
        
        activeSpeechRequest = nil
        isCaptureActive = false
        tearDownEngineUnderLock()
        NSLog("[PearlVoice] Audio pipeline forced into standby. All audio hardware resources released.")
    }
    
    // MARK: - State Inspection
    
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEngineRunning
    }
    
    public var isCaptureEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCaptureActive
    }
    
    public var isSpeechRecognitionAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSpeechRequest != nil
    }
}
