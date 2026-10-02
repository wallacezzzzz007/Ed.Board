import Foundation

public enum PowerOptions {
    public static let lights = [0, 30, 60, 180, 600, 1800, 3600]
    public static let deepSleep = [0, 5, 15, 30, 60, 120]
    public static func valid(seconds: Int, lights: Bool, deepMinutes: Int, keepConnected: Bool) -> Bool {
        (30...7200).contains(seconds) && (1...1440).contains(deepMinutes)
            && (!lights || keepConnected || deepMinutes * 60 > seconds)
    }
    public static func duration(_ seconds: Int) -> String {
        if seconds == 0 { return "Off" }
        if seconds % 3600 == 0 { let n = seconds / 3600; return "\(n) \(n == 1 ? "hour" : "hours")" }
        if seconds % 60 == 0 { let n = seconds / 60; return "\(n) \(n == 1 ? "minute" : "minutes")" }
        return "\(seconds) seconds"
    }
}
