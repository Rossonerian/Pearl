import Foundation

public final class BargeInController: @unchecked Sendable {
    public static let shared = BargeInController()
    
    private let speechEnergyThreshold: Float = 0.22
    private var consecutiveVoiceFrames: Int = 0
    private let framesRequiredForTrigger: Int = 3
    
    public var onBargeInTriggered: (() -> Void)?
    
    public init() {}
    
    public func handleAudioFrame(samples: [Float]) {
        guard SpeechSynthesizerService.shared.speaking else {
            consecutiveVoiceFrames = 0
            return
        }
        
        // Calculate energy
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        let rms = sqrt(sum / max(1.0, Float(samples.count)))
        
        if rms >= speechEnergyThreshold {
            consecutiveVoiceFrames += 1
            if consecutiveVoiceFrames >= framesRequiredForTrigger {
                triggerBargeIn()
            }
        } else {
            consecutiveVoiceFrames = max(0, consecutiveVoiceFrames - 1)
        }
    }
    
    public func triggerBargeIn() {
        consecutiveVoiceFrames = 0
        SpeechSynthesizerService.shared.stopPlayback()
        DispatchQueue.main.async {
            self.onBargeInTriggered?()
        }
    }
}
