import Foundation

public enum SandboxedProcessError: LocalizedError, Sendable {
    case shellInterpretationForbidden(String)
    case neverTierViolation(reason: String)
    case executionFailed(String)
    case timedOut(seconds: Double)
    case processExitedWithNonZero(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .shellInterpretationForbidden(let msg):
            return "Shell interpretation forbidden: \(msg)"
        case .neverTierViolation(let reason):
            return "Execution blocked by Never-Tier security rule: \(reason)"
        case .executionFailed(let msg):
            return "Sandboxed process execution failed: \(msg)"
        case .timedOut(let s):
            return "Sandboxed process timed out after \(s) seconds."
        case .processExitedWithNonZero(let code, let stderr):
            return "Process exited with status \(code): \(stderr)"
        }
    }
}

public struct SandboxedProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Double
    public let sandboxed: Bool
    
    public var success: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String, durationMs: Double, sandboxed: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
        self.sandboxed = sandboxed
    }
}

/// Executes child processes strictly via argv arrays within an Apple Seatbelt sandbox.
/// Direct shell interpreters (`/bin/sh -c`, `bash -c`, `zsh -c`) are hard-blocked by design.
public final class SandboxedProcessRunner: Sendable {
    public static let shared = SandboxedProcessRunner()
    
    public init() {}
    
    /// Executes an executable with strict argv array arguments inside a Seatbelt sandbox.
    ///
    /// - Parameters:
    ///   - executableURL: The URL of the binary to execute (e.g. `/usr/bin/git`).
    ///   - arguments: The argv array (e.g. `["status", "--porcelain"]`).
    ///   - currentDirectoryURL: Optional working directory for the process.
    ///   - environment: Optional environment variables.
    ///   - profile: The Seatbelt profile to enforce (defaults to strict deny profile).
    ///   - timeoutSeconds: Maximum allowable execution duration.
    /// - Returns: `SandboxedProcessResult` containing output, exit status, and timing.
    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        profile: SeatbeltProfile = SeatbeltProfile.strictDenyProfile(),
        timeoutSeconds: Double = 30.0
    ) async throws -> SandboxedProcessResult {
        // 1. Strictly forbid dynamic shell interpreters invoking -c
        let execPath = executableURL.path.lowercased()
        if execPath.hasSuffix("/sh") || execPath.hasSuffix("/bash") || execPath.hasSuffix("/zsh") ||
           execPath == "sh" || execPath == "bash" || execPath == "zsh" {
            if arguments.contains("-c") || arguments.contains("-e") {
                throw SandboxedProcessError.shellInterpretationForbidden(
                    "Executing arbitrary shell command strings via /bin/sh -c is prohibited. Use typed argv arrays."
                )
            }
        }
        
        // 2. Validate against NeverTier rules
        let neverCheck = NeverTierValidator.validate(executable: executableURL.path, arguments: arguments)
        if neverCheck.isDenied {
            throw SandboxedProcessError.neverTierViolation(reason: neverCheck.reason ?? "Never-Tier action hard-blocked")
        }
        
        // 3. Generate Seatbelt profile
        let profileText = profile.generateProfileText()
        
        let start = mach_continuous_time()
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        if let currentDir = currentDirectoryURL {
            task.currentDirectoryURL = currentDir
        }
        if let env = environment {
            task.environment = env
        }
        
        // sandbox-exec -p <profile> <executable> <args...>
        task.arguments = ["-p", profileText, executableURL.path] + arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        
        do {
            try task.run()
        } catch {
            throw SandboxedProcessError.executionFailed(error.localizedDescription)
        }
        
        // Handle process with timeout
        let isTimedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let checkInterval = 0.05
                var elapsed = 0.0
                while task.isRunning && elapsed < timeoutSeconds {
                    Thread.sleep(forTimeInterval: checkInterval)
                    elapsed += checkInterval
                }
                if task.isRunning {
                    task.terminate()
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
        
        let end = mach_continuous_time()
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        let durationMs = Double(end - start) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000.0
        
        if isTimedOut {
            throw SandboxedProcessError.timedOut(seconds: timeoutSeconds)
        }
        
        task.waitUntilExit()
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
        let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        return SandboxedProcessResult(
            exitCode: task.terminationStatus,
            stdout: stdoutStr,
            stderr: stderrStr,
            durationMs: durationMs,
            sandboxed: true
        )
    }
}
