import SwiftUI

enum Theme {
    static let ink = Color(red: 0.125, green: 0.161, blue: 0.125)
    static let inkSoft = Color(red: 0.333, green: 0.376, blue: 0.310)
    static let bg = Color(red: 0.929, green: 0.941, blue: 0.902)
    static let surface = Color(red: 0.973, green: 0.976, blue: 0.953)
    static let surface2 = Color(red: 0.890, green: 0.906, blue: 0.847)
    static let line = Color(red: 0.804, green: 0.824, blue: 0.753)
    static let accent = Color(red: 0.247, green: 0.420, blue: 0.286)
    static let accentSoft = Color(red: 0.863, green: 0.906, blue: 0.847)
    static let warm = Color(red: 0.647, green: 0.416, blue: 0.086)
    static let warmSoft = Color(red: 0.945, green: 0.886, blue: 0.761)

    /// Serif display type for titles — matches the web app's Fraunces
    /// without bundling a custom font file into the app.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Monospace accent type for eyebrows/labels/pills — matches the web
    /// app's IBM Plex Mono without bundling a custom font file.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
