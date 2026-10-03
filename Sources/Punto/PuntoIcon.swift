import AppKit
import CoreGraphics
import Foundation

/// Разбор атрибута `d` SVG-контура в набор замкнутых подконтуров в
/// абсолютных координатах. Поддерживаются команды M L H V C S Q T Z
/// в обоих регистрах — этого достаточно для иконок.
enum SVGPathParser {
    static func subpaths(from data: String) -> [CGPath]? {
        var tokens = tokenize(data)[...]
        var result: [CGPath] = []
        var path: CGMutablePath?
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character?

        func number() -> CGFloat? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens.removeFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        func finish() {
            if let path, !path.isEmpty { result.append(path.copy()!) }
            path = nil
        }

        while let token = tokens.first {
            if case .command(let letter) = token {
                tokens.removeFirst()
                command = letter
                if letter == "Z" || letter == "z" {
                    path?.closeSubpath()
                    current = start
                    finish()
                    lastControl = nil
                    continue
                }
            }
            guard let letter = command else { return nil }
            let relative = letter.isLowercase
            switch letter.uppercased() {
            case "M":
                guard let target = point(relative: relative) else { return nil }
                finish()
                path = CGMutablePath()
                path?.move(to: target)
                current = target
                start = target
                lastControl = nil
                // Следующие пары после M — это L.
                command = relative ? "l" : "L"
            case "L":
                guard let target = point(relative: relative) else { return nil }
                path?.addLine(to: target)
                current = target
                lastControl = nil
            case "H":
                guard let x = number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path?.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path?.addLine(to: current)
                lastControl = nil
            case "C":
                guard let first = point(relative: relative),
                      let second = point(relative: relative),
                      let target = point(relative: relative) else { return nil }
                path?.addCurve(to: target, control1: first, control2: second)
                lastControl = second
                current = target
            case "S":
                let first = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let second = point(relative: relative),
                      let target = point(relative: relative) else { return nil }
                path?.addCurve(to: target, control1: first, control2: second)
                lastControl = second
                current = target
            case "Q":
                guard let control = point(relative: relative),
                      let target = point(relative: relative) else { return nil }
                path?.addQuadCurve(to: target, control: control)
                lastControl = control
                current = target
            case "T":
                let control = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let target = point(relative: relative) else { return nil }
                path?.addQuadCurve(to: target, control: control)
                lastControl = control
                current = target
            default:
                return nil
            }
        }
        finish()
        return result.isEmpty ? nil : result
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for character in data {
            if character.isLetter, character != "e", character != "E" {
                flush()
                tokens.append(.command(character))
            } else if character == "-" || character == "+" {
                // Знак начинает новое число, кроме показателя степени.
                if let last = buffer.last, last == "e" || last == "E" {
                    buffer.append(character)
                } else {
                    flush()
                    buffer.append(character)
                }
            } else if character == "." {
                if buffer.contains(".") { flush() }
                buffer.append(character)
            } else if character.isNumber || character == "e" || character == "E" {
                buffer.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

/// Знак «P» (Resources/parking.svg, SVG Repo) для строки меню и иконки приложения.
enum PuntoIcon {
    enum MenuBarStyle {
        case idle
        case busy
        case listening
        case failed
    }

    /// Атрибут `d` из Resources/parking.svg.
    static let svgPathData = "M400 32H48C21.5 32 0 53.5 0 80v352c0 26.5 21.5 48 48 48h352c26.5 0 48-21.5 48-48V80c0-26.5-21.5-48-48-48zM240 320h-48v48c0 8.8-7.2 16-16 16h-32c-8.8 0-16-7.2-16-16V144c0-8.8 7.2-16 16-16h96c52.9 0 96 43.1 96 96s-43.1 96-96 96zm0-128h-48v64h48c17.6 0 32-14.4 32-32s-14.4-32-32-32z"

    /// Подконтуры: 0 — квадрат знака, 1 — буква P, 2 — отверстие в букве.
    static let subpaths: [CGPath] = SVGPathParser.subpaths(from: svgPathData) ?? []

    static var signBounds: CGRect {
        subpaths.first?.boundingBoxOfPath ?? CGRect(x: 0, y: 32, width: 448, height: 448)
    }

    /// Контуры, вписанные в `rect` с переворотом оси Y (в SVG она направлена вниз).
    static func fitted(_ paths: [CGPath], into rect: CGRect) -> CGPath {
        let bounds = signBounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        let combined = CGMutablePath()
        for path in paths {
            if let copy = path.copy(using: &transform) { combined.addPath(copy) }
        }
        return combined
    }

    /// Значок строки меню. Обычное состояние — шаблон, который macOS
    /// перекрашивает под светлую и тёмную строку меню.
    static func menuBarImage(_ style: MenuBarStyle) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let color: NSColor
            switch style {
            case .idle: color = .black
            case .busy: color = NSColor.black.withAlphaComponent(0.45)
            case .listening: color = .systemRed
            case .failed: color = .systemOrange
            }
            context.addPath(fitted(subpaths, into: rect))
            context.setFillColor(color.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = style == .idle || style == .busy
        image.accessibilityDescription = "Punto"
        return image
    }

    /// Иконка приложения: синяя плитка по сетке иконок macOS с белой буквой P,
    /// как на дорожном знаке. Пропорции буквы берутся из исходного знака.
    static func appIcon(pixels: Int) -> CGImage? {
        let side = CGFloat(pixels)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Сетка macOS: плитка 824 из 1024 с радиусом скругления около 185.
        let tile = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
        let radius = tile.width * 185.4 / 824
        let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -side * 10 / 1024),
            blur: side * 28 / 1024,
            color: CGColor(gray: 0, alpha: 0.3)
        )
        context.addPath(tilePath)
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.38, blue: 0.86, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1),
                CGColor(srgbRed: 0.08, green: 0.33, blue: 0.80, alpha: 1)
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.minY),
            options: []
        )
        context.restoreGState()

        // Буква P (подконтуры 1 и 2) в тех же пропорциях, что и в знаке.
        context.addPath(fitted(Array(subpaths.dropFirst()), into: tile))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath(using: .evenOdd)
        return context.makeImage()
    }

    /// Набор PNG для `iconutil -c icns`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let image = appIcon(pixels: points * scale) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let representation = NSBitmapImageRep(cgImage: image)
                guard let png = representation.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
