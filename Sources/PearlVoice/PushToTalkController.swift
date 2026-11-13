import Foundation

public enum PTTState: Sendable {
    case idle
    case listening
    case processing
    case speaking
}

public final class PushToTalkController: @unchecked Sendable {
    public static let shared = PushToTalkController()
    
    private var state: PTTState = .idle
    private var capturedSamples: [Float] = []
    private let queue = DispatchQueue(label: "com.pearl.voice.ptt", qos: .userInteractive)
    
    public var onStateChanged: ((PTTState) -> Void)?
    public var onUtteranceReadyForDispatch: (([Float]) -> Void)?
    
    public init() {
        AudioCaptureEngine.shared.onAudioBufferReceived = { [weak self] buffer in
            self?.queue.async {
                guard let self = self, self.state == .listening else { return }
                self.capturedSamples.append(contentsOf: buffer)
                BargeInController.shared.handleAudioFrame(samples: buffer)
            }
        }
    }
    
    public func onKeyDown() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // If speaking, key down acts as instant barge-in cancel
            if SpeechSynthesizerService.shared.speaking {
                BargeInController.shared.triggerBargeIn()
            }
            
            self.state = .listening
            self.capturedSamples.removeAll(keepingCapacity: true)
            
            try? AudioCaptureEngine.shared.startCapture()
            
            DispatchQueue.main.async {
                self.onStateChanged?(.listening)
            }
        }
    }
    
    public func onKeyUp() {
        queue.async { [weak self] in
            guard let self = self, self.state == .listening else { return }
            
            AudioCaptureEngine.shared.stopCapture()
            self.state = .processing
            
            let audioCopy = self.capturedSamples
            
            DispatchQueue.main.async {
                self.onStateChanged?(.processing)
                self.onUtteranceReadyForDispatch?(audioCopy)
            }
        }
    }
    
    public func markIdle() {
        queue.async { [weak self] in
            self?.state = .idle
            DispatchQueue.main.async {
                self?.onStateChanged?(.idle)
            }
        }
    }
    
    public var currentState: PTTState {
        return state
    }
}
