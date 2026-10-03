import Carbon.HIToolbox

enum ListeningShortcut: String, CaseIterable, Codable, Identifiable, Sendable {
    case optionZ
    case controlOptionSpace
    var id: String { rawValue }
    var title: String { self == .optionZ ? "⌥Z" : "⌃⌥Space" }
    var label: String { self == .optionZ ? "Option + Z" : "Control + Option + Space" }
    var keyCode: UInt32 { UInt32(self == .optionZ ? kVK_ANSI_Z : kVK_Space) }
    var modifiers: UInt32 { UInt32(self == .optionZ ? optionKey : controlKey | optionKey) }
}
