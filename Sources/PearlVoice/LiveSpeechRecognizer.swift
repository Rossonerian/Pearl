import AVFoundation
import Foundation
import Speech

public final class LiveSpeechRecognizer: NSObject, @unchecked Sendable {
    public static let shared = LiveSpeechRecognizer()
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var isListening = false
    private var silenceTimer: Timer?
    private var lastTranscript: String = ""
    
    public var onPartialTranscript: ((String) -> Void)?
    public var onFinalTranscript: ((String) -> Void)?
    public var onAudioLevelUpdated: ((Float) -> Void)?
    public var onError: ((Error) -> Void)?
    
    public override init() {
        super.init()
    }
    
    public func startListening() throws {
        stopListening(finishTranscription: false)
        
        let audioSessionNode = audioEngine.inputNode
        let recordingFormat = audioSessionNode.outputFormat(forBus: 0)
        
        guard recordingFormat.sampleRate > 0 else {
            throw NSError(domain: "LiveSpeechRecognizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone hardware unavailable."])
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        self.lastTranscript = ""
        self.isListening = true
        
        audioSessionNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.isListening else { return }
            request.append(buffer)
            
            // Calculate audio level for 60 Hz waveform meter
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += channelData[i] * channelData[i]
                    }
                    let rms = sqrt(sum / Float(frameLength))
                    let normalized = min(1.0, max(0.05, rms * 5.0))
                    DispatchQueue.main.async {
                        self.onAudioLevelUpdated?(normalized)
                    }
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastTranscript = text
                
                DispatchQueue.main.async {
                    self.onPartialTranscript?(text)
                    self.resetSilenceTimer()
                }
                
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.completeListening()
                    }
                }
            }
            
            if let error = error {
                let nsError = error as NSError
                // Filter out normal speech timeout / cancellation codes (code 209/216)
                if nsError.domain != "kAFAssistantErrorDomain" || (nsError.code != 209 && nsError.code != 216) {
                    DispatchQueue.main.async {
                        self.onError?(error)
                    }
                }
            }
        }
    }
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        // Automatically finalize if 1.2s of silence after speech detected
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.completeListening()
        }
    }
    
    public func completeListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        guard isListening else { return }
        let transcript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening(finishTranscription: true)
        
        if !transcript.isEmpty {
            onFinalTranscript?(transcript)
        }
    }
    
    public func stopListening(finishTranscription: Bool = false) {
        isListening = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        if !finishTranscription {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
    }
    
    public var active: Bool {
        return isListening
    }
}
