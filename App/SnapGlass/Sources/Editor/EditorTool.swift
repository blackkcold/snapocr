import AnnotationCore
import AppKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable, Hashable {
    case select
    case arrow
    case rect
    case text
    case pen
    case highlight
    case blur
    case crop
    case ocr

    var id: String { rawValue }

    var annotationTool: AnnotationToolType? {
        switch self {
        case .select, .ocr: nil
        case .arrow: .arrow
        case .rect: .rect
        case .text: .text
        case .pen: .pen
        case .highlight: .highlight
        case .blur: .blur
        case .crop: .crop
        }
    }

    var iconName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .blur: "drop.halffull"
        case .crop: "crop"
        case .ocr: "text.viewfinder"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .text: "Text"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .blur: "Blur"
        case .crop: "Crop"
        case .ocr: "OCR Text"
        }
    }
}

enum AnnotationStylePreset: String, CaseIterable, Identifiable, Hashable {
    case emphasis
    case note
    case subtle
    case monochrome
    case custom

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .emphasis: "Emphasis"
        case .note: "Note"
        case .subtle: "Subtle"
        case .monochrome: "Monochrome"
        case .custom: "Custom"
        }
    }

    var color: Color {
        switch self {
        case .emphasis: .red
        case .note: .yellow
        case .subtle: .blue
        case .monochrome: .white
        case .custom: .red
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .emphasis: 5
        case .note: 3
        case .subtle: 2
        case .monochrome: 2
        case .custom: 3
        }
    }

    var opacity: CGFloat {
        switch self {
        case .emphasis, .note, .monochrome, .custom: 1
        case .subtle: 0.65
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .emphasis: 36
        case .note: 28
        case .subtle, .monochrome, .custom: 24
        }
    }
}
