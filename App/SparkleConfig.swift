import Foundation

/// Sparkle 2 Configuration & Security Parameters for Pearl V2.
/// Enforces EdDSA cryptographic signature verification and zero telemetry.
public struct SparkleConfig: Sendable {
    /// EdDSA (ed25519) public key placeholder for verifying appcast signatures.
    /// Replace with your production offline-generated EdDSA public key before final release.
    public static let defaultPublicKey = "c2hhMjU2X2VkMjU1MTlfcHVibGljX2tleV9wbGFjZWhvbGRlcl9wZWFybHYyCg=="
    
    /// Sparkle appcast XML feed URL.
    public static let defaultFeedURL = "https://raw.githubusercontent.com/rossonerian/Pearl/main/appcast.xml"
    
    /// System profiling is strictly disabled (zero anonymous hardware telemetry sent).
    public static let enableSystemProfiling = false
    
    /// Standard bundle Info.plist dictionary keys for Sparkle 2.
    public static var infoPlistEntries: [String: Any] {
        return [
            "SUFeedURL": defaultFeedURL,
            "SUPublicEDKey": defaultPublicKey,
            "SUEnableSystemProfiling": enableSystemProfiling,
            "SUAutomaticallyChecksForUpdates": true,
            "SUAutomaticallyUpdate": false,
            "SUScheduledCheckInterval": 86400 // Daily check
        ]
    }
}
