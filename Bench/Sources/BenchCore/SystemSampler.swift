import Foundation

public struct SystemStateSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let thermalState: String
    public let physicalFootprintBytes: UInt64
    public let swapUsedBytes: UInt64
    public let macOSVersion: String
    public let cpuBrand: String
    
    public init(timestamp: Date = Date(), thermalState: String, physicalFootprintBytes: UInt64, swapUsedBytes: UInt64, macOSVersion: String, cpuBrand: String) {
        self.timestamp = timestamp
        self.thermalState = thermalState
        self.physicalFootprintBytes = physicalFootprintBytes
        self.swapUsedBytes = swapUsedBytes
        self.macOSVersion = macOSVersion
        self.cpuBrand = cpuBrand
    }
}

public enum SystemSampler {
    public static func currentThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    
    public static func captureFootprint(pid: pid_t) -> UInt64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        task.arguments = ["--noCategories", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return 0 }
            
            // Look for phys_footprint: <bytes> or <number> <unit>
            for line in output.components(separatedBy: .newlines) {
                if line.contains("phys_footprint:") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count > 1 {
                        let valStr = parts[1].trimmingCharacters(in: .whitespaces)
                        return parseMemoryString(valStr)
                    }
                }
            }
        } catch {
            return 0
        }
        return 0
    }
    
    public static func captureSystemInfo() -> (os: String, cpu: String) {
        var osVersion = "macOS 27.2.1"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        task.arguments = ["-productVersion"]
        let pipe = Pipe()
        task.standardOutput = pipe
        if (try? task.run()) != nil {
            task.waitUntilExit()
            if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                osVersion = "macOS " + str
            }
        }
        
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let cpu = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)
        return (osVersion, cpu.isEmpty ? "Apple A18 Pro" : cpu)
    }
    
    private static func parseMemoryString(_ str: String) -> UInt64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: .whitespaces)
        guard let num = Double(parts[0]) else { return 0 }
        if parts.count > 1 {
            let unit = parts[1].uppercased()
            if unit.hasPrefix("K") { return UInt64(num * 1024) }
            if unit.hasPrefix("M") { return UInt64(num * 1024 * 1024) }
            if unit.hasPrefix("G") { return UInt64(num * 1024 * 1024 * 1024) }
        }
        return UInt64(num)
    }
}
