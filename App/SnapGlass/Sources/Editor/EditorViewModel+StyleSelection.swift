import AnnotationCore
import AppKit
import SwiftUI

// MARK: - EditorViewModel Style Selection

extension EditorViewModel {
  func setSelectedColor(_ color: Color) {
    selectedColor = color
    selectedPreset = .custom
    if selectedNode != nil {
      updateSelectedStyle()
    } else if fillEnabled {
      fillColor = color
    }
  }

  public func selectNode(_ id: UUID?) {
    selectedNodeID = id
    guard let node = selectedNode else { return }
    selectedColor = Color(nsColor: NSColor(cgColor: node.color ?? cgColor) ?? .red)
    strokeWidth = node.lineWidth
    annotationOpacity = node.opacity
    fillEnabled = node.fillColor != nil
    if let fill = node.fillColor, let nsFill = NSColor(cgColor: fill) {
      fillColor = Color(nsColor: nsFill)
    }
    strokeStyle = node.strokeStyle
    cornerRadius = node.cornerRadius
    arrowStyle = node.arrowStyle
    fontName = node.fontName
    fontSize = node.fontSize
    textAlignment = node.textAlignment
    blurMode = node.blurMode
    blurIntensity = node.blurIntensity
  }

  func applyPreset(_ preset: AnnotationStylePreset) {
    selectedPreset = preset
    guard preset != .custom else { return }
    selectedColor = preset.color
    strokeWidth = preset.lineWidth
    annotationOpacity = preset.opacity
    fontSize = preset.fontSize
    switch preset {
    case .emphasis:
      fillEnabled = false
      strokeStyle = .solid
    case .note:
      fillEnabled = true
      fillColor = .black.opacity(0.75)
      strokeStyle = .solid
    case .subtle:
      fillEnabled = false
      strokeStyle = .dashed
    case .monochrome:
      fillEnabled = true
      fillColor = .black.opacity(0.65)
      strokeStyle = .solid
    case .custom:
      break
    }
    if selectedNode != nil {
      updateSelectedStyle()
    }
  }
}
