import AVFoundation
import Foundation

public final class SpeechSynthesizerService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = SpeechSynthesizerService()
    
    private let synthesizer = AVSpeechSynthesizer()
    private var isPlaying = false
    private let speechQueue = DispatchQueue(label: "com.pearl.voice.tts", qos: .userInteractive)
    
    public var onPlaybackStarted: (() -> Void)?
    public var onPlaybackFinished: (() -> Void)?
    
    public override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    public func speak(text: String, voiceLocale: String = "en-GB") {
        speechQueue.async { [weak self] in
            guard let self = self else { return }
            
            let utterance = AVSpeechUtterance(string: text)
            let voice = AVSpeechSynthesisVoice(language: voiceLocale) ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.pitchMultiplier = 1.0
            
            self.isPlaying = true
            self.synthesizer.speak(utterance)
        }
    }
    
    public func stopPlayback() {
        speechQueue.async { [weak self] in
            guard let self = self else { return }
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.isPlaying = false
            DispatchQueue.main.async {
                self.onPlaybackFinished?()
            }
        }
    }
    
    public var speaking: Bool {
        return synthesizer.isSpeaking || isPlaying
    }
    
    // AVSpeechSynthesizerDelegate
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isPlaying = true
        DispatchQueue.main.async {
            self.onPlaybackStarted?()
        }
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isPlaying = false
        DispatchQueue.main.async {
            self.onPlaybackFinished?()
        }
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isPlaying = false
        DispatchQueue.main.async {
            self.onPlaybackFinished?()
        }
    }
}
