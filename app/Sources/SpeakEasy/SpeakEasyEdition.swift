import Foundation

enum SpeakEasyEdition {
    static let isDevelopment = Bundle.main.bundleIdentifier == "com.osirismedici.speakeasy-karen-dev"
    static var displayName: String { isDevelopment ? "Echo" : "SpeakEasy" }
    static var supportFolder: String { isDevelopment ? "SpeakEasy Karen Dev" : "SpeakEasy" }
    static var configFolder: String { isDevelopment ? ".config/speakeasy-karen-dev" : ".config/speakeasy" }
    static var playerSocket: String { isDevelopment ? "/tmp/speakeasy-karen-dev-player.sock" : "/tmp/speakeasy-player.sock" }
    static var hudPipe: String { isDevelopment ? "/tmp/speakeasy-karen-dev-hud.fifo" : "/tmp/speakeasy-hud.fifo" }
}
