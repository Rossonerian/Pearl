import AVFoundation
import Foundation
import Speech

/// Real-time speech recognition engine backed by `AudioPipelineService`.
///
/// Uses the single unified `AVAudioEngine` tap provided by `AudioPipelineService`,
/// eliminating duplicate audio engines and avoiding hardware tap collisions.
public final class LiveSpeechRecognizer: NSObject, @unchecked Sendable {
    public static let shared = LiveSpeechRecognizer()
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var isListening = false
    private var silenceTimer: Timer?
    private var lastTranscript: String = ""
    
    public var onPartialTranscript: ((String) -> Void)?
    public var onFinalTranscript: ((String) -> Void)?
    public var onAudioLevelUpdated: ((Float) -> Void)?
    public var onError: ((Error) -> Void)?
    
    public override init() {
        super.init()
        
        // Forward RMS audio level updates from the unified audio pipeline
        AudioPipelineService.shared.onLevelMeterUpdated = { [weak self] level in
            self?.onAudioLevelUpdated?(level)
        }
    }
    
    public func startListening() throws {
        stopListening(finishTranscription: false)
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        self.lastTranscript = ""
        self.isListening = true
        
        // Bind request to unified single-engine audio tap
        try AudioPipelineService.shared.attachSpeechRecognitionRequest(request)
        
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
                // Filter out standard speech timeout / cancellation codes (code 209/216)
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
        // Automatically finalize if 1.2s of silence is detected after speech
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
        
        AudioPipelineService.shared.detachSpeechRecognitionRequest()
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        if !finishTranscription {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
    }
    
    public func enterStandby() {
        stopListening(finishTranscription: false)
        AudioPipelineService.shared.enterStandby()
    }
    
    public var active: Bool {
        return isListening
    }
}
