import AppKit
import SwiftUI

enum Ink {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let n = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
        }
    }
    static let sidebarText = color(0x495057, 0xFFFFFF)
    static let separator = color(0xDDDDDD, 0x2D2D2D)
    static let paper = color(0xFFFFFF, 0x1E1E1E)
    static let sidebar = color(0xFBFBFB, 0x100F11)
    static let text = color(0x000000, 0xFFFFFF)
    static let muted = color(0xADB5BD, 0x888888)
    static let syntax = color(0xB8BDC2, 0x686868)
    static let accent = color(0x42A5F5, 0x4598F7)
    static let selection = color(0xBBDFFC, 0x264766)
    static let code = color(0xDEE2E6, 0x232223)
}


// Soft, legible colors for notebook icons in either appearance.
enum NotebookTint: String, CaseIterable {
    case sky, mint, lavender, peach, rose, butter
    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .sky: return Ink.color(0x759BB8, 0xA8CBE6)
        case .mint: return Ink.color(0x739B87, 0xA7D4BD)
        case .lavender: return Ink.color(0x9783B1, 0xC7B6E6)
        case .peach: return Ink.color(0xB98A6C, 0xECC3A8)
        case .rose: return Ink.color(0xB57F91, 0xE6B3C4)
        case .butter: return Ink.color(0xA3975D, 0xE2D49C)
        }
    }
}
