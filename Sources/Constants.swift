import Foundation

public enum MuxerConstants {
    public static let deviceIP = "10.7.0.1"
    public static let lockdowndPort: UInt16 = 62078

    public static let usbmuxdHost = "127.0.0.1"
    public static let usbmuxdPort: UInt16 = 27015
    public static let usbmuxdSocket = "\(usbmuxdHost):\(usbmuxdPort)"
    
    public static let heartbeatTimeoutMs: UInt32 = 12000
    public static let deviceFetchTimeoutMs: UInt16 = 5000
    public static let deviceFetchSleepMs: UInt32 = 250
    
    public static let pkgPath = "PublicStaging"
    public static let usbmuxdEnvKey = "USBMUXD_SOCKET_ADDRESS"

    public static let pre17VersionsURL = "https://raw.githubusercontent.com/jkcoxson/JitStreamer/master/versions.json"
    public static let ddiImageURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
    public static let ddiTrustcacheURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
    public static let ddiManifestURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
}
