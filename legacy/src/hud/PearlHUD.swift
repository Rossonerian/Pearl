import AppKit
import AVFoundation

class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 49 { // ESC or Space
            NotificationCenter.default.post(name: NSNotification.Name("PearlHUDDismissRequested"), object: nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

class LiquidGlassView: NSView {
    private let backgroundBlur = NSVisualEffectView()
    private let glassGradientLayer = CAGradientLayer()
    private let borderGradientLayer = CAGradientLayer()
    private let innerGlowLayer = CALayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    override func mouseDown(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("PearlHUDDismissRequested"), object: nil)
    }
    
    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        
        let cornerRadius = bounds.height / 2
        
        // 1. Deep frosted vibrancy blur
        backgroundBlur.frame = bounds
        backgroundBlur.autoresizingMask = [.width, .height]
        backgroundBlur.material = .hudWindow
        backgroundBlur.blendingMode = .behindWindow
        backgroundBlur.state = .active
        backgroundBlur.wantsLayer = true
        backgroundBlur.layer?.cornerRadius = cornerRadius
        backgroundBlur.layer?.masksToBounds = true
        addSubview(backgroundBlur)
        
        // 2. Liquid Glass specular reflection gradient (top-lit sheen)
        glassGradientLayer.frame = bounds
        glassGradientLayer.cornerRadius = cornerRadius
        glassGradientLayer.colors = [
            NSColor(white: 1.0, alpha: 0.18).cgColor,
            NSColor(white: 1.0, alpha: 0.04).cgColor,
            NSColor(white: 0.0, alpha: 0.08).cgColor,
            NSColor(white: 1.0, alpha: 0.06).cgColor
        ]
        glassGradientLayer.locations = [0.0, 0.42, 0.70, 1.0]
        glassGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        glassGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        layer?.addSublayer(glassGradientLayer)
        
        // 3. Ultra-refined refractive bezel border (liquid edge)
        borderGradientLayer.frame = bounds
        borderGradientLayer.cornerRadius = cornerRadius
        borderGradientLayer.colors = [
            NSColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 0.45).cgColor,
            NSColor(white: 1.0, alpha: 0.15).cgColor,
            NSColor(white: 0.3, alpha: 0.12).cgColor,
            NSColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 0.28).cgColor
        ]
        borderGradientLayer.locations = [0.0, 0.35, 0.75, 1.0]
        borderGradientLayer.startPoint = CGPoint(x: 0.2, y: 1.0)
        borderGradientLayer.endPoint = CGPoint(x: 0.8, y: 0.0)
        
        // Mask borderGradientLayer to outline only (1.2pt border)
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        path.addRoundedRect(in: bounds.insetBy(dx: 1.2, dy: 1.2), cornerWidth: cornerRadius - 1.2, cornerHeight: cornerRadius - 1.2)
        mask.path = path
        mask.fillRule = .evenOdd
        borderGradientLayer.mask = mask
        layer?.addSublayer(borderGradientLayer)
        
        // 4. Default ambient glow
        applyCircadianGlow(mood: "default")
    }
    
    func applyCircadianGlow(mood: String) {
        let glowColor: CGColor
        let highlightColor: CGColor
        
        switch mood {
        case "late_night_introspective":
            glowColor = NSColor(red: 0.05, green: 0.65, blue: 0.98, alpha: 0.45).cgColor // Moonlit Cyan
            highlightColor = NSColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.50).cgColor
        case "morning_clarity":
            glowColor = NSColor(red: 0.98, green: 0.65, blue: 0.12, alpha: 0.45).cgColor // Golden Sunrise
            highlightColor = NSColor(red: 1.0, green: 0.88, blue: 0.60, alpha: 0.50).cgColor
        case "focused_builder":
            glowColor = NSColor(red: 0.22, green: 0.52, blue: 1.0, alpha: 0.45).cgColor // Cyber Cobalt
            highlightColor = NSColor(red: 0.65, green: 0.82, blue: 1.0, alpha: 0.50).cgColor
        case "reflective_wind_down":
            glowColor = NSColor(red: 0.68, green: 0.35, blue: 0.98, alpha: 0.45).cgColor // Twilight Amethyst
            highlightColor = NSColor(red: 0.85, green: 0.70, blue: 1.0, alpha: 0.50).cgColor
        default:
            glowColor = NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 0.38).cgColor
            highlightColor = NSColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 0.40).cgColor
        }
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        layer?.shadowColor = glowColor
        layer?.shadowOpacity = 0.55
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 18
        
        borderGradientLayer.colors = [
            highlightColor,
            NSColor(white: 1.0, alpha: 0.15).cgColor,
            NSColor(white: 0.3, alpha: 0.10).cgColor,
            glowColor
        ]
        CATransaction.commit()
    }
    
    override func layout() {
        super.layout()
        backgroundBlur.frame = bounds
        glassGradientLayer.frame = bounds
        borderGradientLayer.frame = bounds
        
        let cornerRadius = bounds.height / 2
        backgroundBlur.layer?.cornerRadius = cornerRadius
        glassGradientLayer.cornerRadius = cornerRadius
        borderGradientLayer.cornerRadius = cornerRadius
        
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        path.addRoundedRect(in: bounds.insetBy(dx: 1.2, dy: 1.2), cornerWidth: cornerRadius - 1.2, cornerHeight: cornerRadius - 1.2)
        mask.path = path
        mask.fillRule = .evenOdd
        borderGradientLayer.mask = mask
    }
}

class WaveformView: NSView {
    private let barCount = 7
    private var barLayers: [CALayer] = []
    private var phase: Double = 0.0
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }
    
    private func setupBars() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        
        let barWidth: CGFloat = 3.5
        let spacing: CGFloat = 5.0
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.height / 2
        
        // Pearlescent liquid crystal luminescence
        let colors = [
            NSColor(red: 0.68, green: 0.85, blue: 1.0, alpha: 0.85).cgColor,
            NSColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 0.95).cgColor,
            NSColor(white: 1.0, alpha: 1.0).cgColor,
            NSColor(red: 0.92, green: 0.88, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(white: 1.0, alpha: 1.0).cgColor,
            NSColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 0.95).cgColor,
            NSColor(red: 0.68, green: 0.85, blue: 1.0, alpha: 0.85).cgColor
        ]
        
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let bar = CALayer()
            bar.backgroundColor = colors[i % colors.count]
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(x: x, y: centerY - 2, width: barWidth, height: 4)
            
            bar.shadowColor = colors[i % colors.count]
            bar.shadowOpacity = 0.8
            bar.shadowRadius = 4.0
            bar.shadowOffset = .zero
            
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }
    
    override func layout() {
        super.layout()
        setupBars()
    }
    
    // Live Audio Metering (Speaking State)
    func updateLevels(normalized: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        
        let centerY = bounds.height / 2
        let maxHeight = bounds.height * 0.72
        let minHeight: CGFloat = 4.0
        
        let multipliers: [CGFloat] = [0.38, 0.68, 0.95, 1.0, 0.92, 0.64, 0.34]
        
        for (i, bar) in barLayers.enumerated() {
            let m = multipliers[i % multipliers.count]
            let h = max(minHeight, min(maxHeight, normalized * maxHeight * m + minHeight))
            let currentX = bar.frame.origin.x
            let currentW = bar.frame.width
            bar.frame = CGRect(x: currentX, y: centerY - (h / 2), width: currentW, height: h)
        }
        CATransaction.commit()
    }
    
    // Smooth Organic Breathing Wave (Thinking State)
    func updateThinking() {
        phase += 0.09
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.04)
        
        let centerY = bounds.height / 2
        let minHeight: CGFloat = 3.5
        let maxHeight: CGFloat = 14.5
        
        // Fluid harmonic traveling ripple with ambient breathing modulation
        let breathing = (sin(phase * 0.5) + 1.0) * 0.35 + 0.65
        
        for (i, bar) in barLayers.enumerated() {
            let spatialOffset = Double(i) * 0.65
            let sine = (sin(phase + spatialOffset) + 1.0) / 2.0
            let h = minHeight + CGFloat(sine * breathing) * (maxHeight - minHeight)
            let currentX = bar.frame.origin.x
            let currentW = bar.frame.width
            bar.frame = CGRect(x: currentX, y: centerY - (h / 2), width: currentW, height: h)
        }
        CATransaction.commit()
    }
}

class PearlHUDController: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    var window: HUDWindow!
    var waveformView: WaveformView!
    var liquidGlassView: LiquidGlassView!
    var audioPlayer: AVAudioPlayer?
    var meterTimer: Timer?
    var watchTimer: Timer?
    var mode: String = "test"
    var audioPath: String = ""
    var mood: String = "late_night_introspective"
    var durationSeconds: Double = 3.0
    var isDismissing: Bool = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()
        setupHUDWindow()
        setupDismissListener()
        animateEntrance()
        startInteraction()
    }
    
    private func parseArguments() {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg == "--play" && i + 1 < args.count {
                mode = "play"
                audioPath = args[i + 1]
                i += 1
            } else if arg == "--think-and-play" && i + 1 < args.count {
                mode = "think_and_play"
                audioPath = args[i + 1]
                i += 1
            } else if arg == "--mood" && i + 1 < args.count {
                mood = args[i + 1]
                i += 1
            } else if arg == "--duration" && i + 1 < args.count {
                if let d = Double(args[i + 1]) { durationSeconds = d }
                i += 1
            } else if arg == "--test" {
                mode = "test"
            }
            i += 1
        }
    }
    
    private func setupHUDWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        
        let hudWidth: CGFloat = 170
        let hudHeight: CGFloat = 40
        let x = screenFrame.origin.x + (screenFrame.width - hudWidth) / 2
        let y = screenFrame.origin.y + screenFrame.height - hudHeight - 34
        
        let rect = NSRect(x: x, y: y, width: hudWidth, height: hudHeight)
        window = HUDWindow(contentRect: rect,
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = false
        
        // Base Liquid Glass
        liquidGlassView = LiquidGlassView(frame: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight))
        liquidGlassView.applyCircadianGlow(mood: mood)
        
        // Waveform
        waveformView = WaveformView(frame: liquidGlassView.bounds)
        liquidGlassView.addSubview(waveformView)
        
        window.contentView = liquidGlassView
        window.alphaValue = 0.0
    }
    
    private func setupDismissListener() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("PearlHUDDismissRequested"), object: nil, queue: .main) { [weak self] _ in
            self?.dismissHUD()
        }
    }
    
    private func animateEntrance() {
        window.makeKeyAndOrderFront(nil)
        
        let currentFrame = window.frame
        let startFrame = NSRect(x: currentFrame.origin.x,
                                y: currentFrame.origin.y + 16,
                                width: currentFrame.width,
                                height: currentFrame.height)
        window.setFrame(startFrame, display: false)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            window.animator().setFrame(currentFrame, display: true)
            window.animator().alphaValue = 1.0
        }
    }
    
    private func animateExit() {
        guard !isDismissing else { return }
        isDismissing = true
        
        let currentFrame = window.frame
        let endFrame = NSRect(x: currentFrame.origin.x,
                              y: currentFrame.origin.y + 14,
                              width: currentFrame.width,
                              height: currentFrame.height)
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }
    
    private func dismissHUD() {
        audioPlayer?.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        watchTimer?.invalidate()
        watchTimer = nil
        animateExit()
    }
    
    private func startInteraction() {
        if mode == "think_and_play" && !audioPath.isEmpty {
            startThinkingAndWatch()
        } else if mode == "play" && !audioPath.isEmpty {
            playAudioFile(audioPath)
        } else {
            // Test Mode: play synthetic wave for 2.8s
            var t: Double = 0
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                t += 0.22
                let normalized = CGFloat((sin(t) + 1.0) / 2.0 * 0.85 + 0.1)
                self?.waveformView.updateLevels(normalized: normalized)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                self?.finishInteraction()
            }
        }
    }
    
    private func startThinkingAndWatch() {
        // 1. Run the undulating Thinking ripple immediately
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
            self?.waveformView.updateThinking()
        }
        
        // 2. Poll for audio file arrival or failure signal
        let startTime = Date()
        let failPath = "/tmp/pearl_speech.failed"
        let cancelPath = "/tmp/pearl_speech.cancel"
        
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            
            // Check cancel / failure
            if FileManager.default.fileExists(atPath: failPath) || FileManager.default.fileExists(atPath: cancelPath) {
                timer.invalidate()
                self.meterTimer?.invalidate()
                self.finishInteraction()
                return
            }
            
            // Timeout safety (14 seconds max thinking)
            if Date().timeIntervalSince(startTime) > 14.0 {
                timer.invalidate()
                self.meterTimer?.invalidate()
                self.finishInteraction()
                return
            }
            
            // Check if audio file has appeared and is completely written (>500 bytes)
            if FileManager.default.fileExists(atPath: self.audioPath) {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: self.audioPath)
                    if let size = attrs[.size] as? UInt64, size > 500 {
                        timer.invalidate()
                        self.meterTimer?.invalidate()
                        self.meterTimer = nil
                        // Seamless morph into speech playback
                        self.playAudioFile(self.audioPath)
                    }
                } catch {
                    // Still writing
                }
            }
        }
    }
    
    private func playAudioFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.isMeteringEnabled = true
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.audioPlayer else { return }
                player.updateMeters()
                let avg = player.averagePower(forChannel: 0)
                let normalized = max(0.05, min(1.0, CGFloat((avg + 45.0) / 45.0)))
                self.waveformView.updateLevels(normalized: normalized)
            }
        } catch {
            finishInteraction()
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishInteraction()
    }
    
    private func finishInteraction() {
        meterTimer?.invalidate()
        meterTimer = nil
        watchTimer?.invalidate()
        watchTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            self?.animateExit()
        }
    }
}

let app = NSApplication.shared
let controller = PearlHUDController()
app.delegate = controller
app.run()