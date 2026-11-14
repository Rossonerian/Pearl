import CoreGraphics
import Foundation
import PearlCore

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

#if canImport(Vision)
import Vision
#endif

// MARK: - ScreenReadTool

public final class ScreenReadTool: PearlTool {
    public let name = "read_screen_text"
    public let description = "Read visible text displayed on screen using ScreenCaptureKit and Vision OCR in-memory"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = [.screenRecording]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        #if canImport(ScreenCaptureKit) && canImport(Vision)
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    return ToolResult(
                        success: false,
                        message: "No active display found to capture.",
                        trust: .untrusted
                    )
                }
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                
                let text = try await recognizeText(in: cgImage)
                
                // Screen content can contain indirect prompt injection, so taint context and return untrusted
                TaintTracker.shared.markTainted(
                    source: "screen_ocr",
                    reason: "Extracted on-screen text via Vision OCR (\(text.count) chars)"
                )
                
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ToolResult(
                        success: true,
                        message: "Screen capture completed, but no readable text was detected.",
                        trust: .untrusted
                    )
                }
                
                return ToolResult(
                    success: true,
                    message: "Screen Text (OCR):\n\(text)",
                    trust: .untrusted
                )
            } catch {
                return ToolResult(
                    success: false,
                    message: "Screen Recording permission denied or display capture unavailable: \(error.localizedDescription)",
                    trust: .untrusted
                )
            }
        }
        #endif
        
        return ToolResult(
            success: false,
            message: "ScreenCaptureKit and Vision OCR are unavailable on this platform/configuration.",
            trust: .untrusted
        )
    }
    
    /// Performs in-memory Vision text recognition on a CGImage without writing to disk.
    public func recognizeText(in image: CGImage) async throws -> String {
        #if canImport(Vision)
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let recognizedLines = results.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: recognizedLines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #else
        return ""
        #endif
    }
}
