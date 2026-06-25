import Cocoa
import CoreGraphics
import UniformTypeIdentifiers

// ============================================================================
//  DesktopScaleRuler — floating screen ruler for on-screen PDF plans.
//
//  • CALIBRATE: stretch the ruler over a known dimension, type its real length.
//  • PRESETS (1:100 / 1:50 / custom): computed from the display's real physical
//    size, correct at Preview "Actual Size". Run "Calibrate Display" once for
//    perfect accuracy.
//  • MEASURE MODES: Ruler (default), Distance (two-point length + angle), Area (m²),
//    Count (click tally). Measurements feed a named-set TAKEOFF list with
//    subtotals, grand totals and CSV export. Settings + takeoff persist.
// ============================================================================

let FALLBACK_MM_PER_POINT = 25.4 / 108.0

/// User-set true physical mm-per-point for this display (from Calibrate Display).
var displayOverrideMMPerPoint: Double?

func physMMPerPoint(for screen: NSScreen?) -> Double {
    if let o = displayOverrideMMPerPoint, o > 0 { return o }
    guard let screen = screen,
          let num = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber
    else { return FALLBACK_MM_PER_POINT }
    let displayID = CGDirectDisplayID(num.uint32Value)
    let mm = CGDisplayScreenSize(displayID)
    let pts = screen.frame.width
    guard mm.width > 0, pts > 0 else { return FALLBACK_MM_PER_POINT }
    return Double(mm.width) / Double(pts)
}

enum MeasureMode { case ruler, distance, area, count }

// MARK: - Shared model -------------------------------------------------------

final class RulerModel {
    static let shared = RulerModel()

    var mmPerPoint: Double = 100.0 * FALLBACK_MM_PER_POINT
    var scaleRatio: Double = 100
    var useMetres: Bool = false
    var showGuide: Bool = true
    var showLeadLines: Bool = true
    var calibrated: Bool = false       // true if set from a known dimension
    var mode: MeasureMode = .ruler

    var onChange: (() -> Void)?
    func notify() { onChange?() }

    func realMM(points: CGFloat) -> Double { Double(points) * mmPerPoint }

    func formatted(points: CGFloat) -> String {
        let mm = realMM(points: points)
        if useMetres { return String(format: "%.3f m", mm / 1000.0) }
        return String(format: "%.0f mm", mm)
    }

    var scaleLabel: String { String(format: "1:%g", scaleRatio) }
}

// MARK: - Takeoff store ------------------------------------------------------

struct TakeoffItem: Codable {
    enum Kind: String, Codable { case distance, area, count }
    var kind: Kind
    var value: Double      // distance: mm, area: m², count: 1 per click
    var set: String
}

final class TakeoffStore {
    static let shared = TakeoffStore()
    private(set) var items: [TakeoffItem] = []
    var activeSet: String = "Set 1"
    var onChange: (() -> Void)?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopScaleRuler", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("takeoff.json")
    }

    func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TakeoffItem].self, from: d) else { return }
        items = decoded
        if let last = items.last { activeSet = last.set }
    }
    private func save() { if let d = try? JSONEncoder().encode(items) { try? d.write(to: fileURL) } }

    func add(_ kind: TakeoffItem.Kind, _ value: Double) {
        items.append(TakeoffItem(kind: kind, value: value, set: activeSet)); save(); onChange?()
    }
    func undoLast() { guard !items.isEmpty else { return }; items.removeLast(); save(); onChange?() }
    func clearAll() { items.removeAll(); save(); onChange?() }
    func newSet(_ name: String) { activeSet = name; onChange?() }

    private func orderedSets() -> [String] {
        var seen: [String] = []
        for it in items where !seen.contains(it.set) { seen.append(it.set) }
        if !seen.contains(activeSet) { seen.append(activeSet) }
        return seen
    }

    func summaryText() -> String {
        var out = ""
        var gLen = 0.0, gArea = 0.0, gCount = 0
        for set in orderedSets() {
            let its = items.filter { $0.set == set }
            out += "▸ \(set)\(set == activeSet ? "   (active)" : "")\n"
            var sLen = 0.0, sArea = 0.0, sCount = 0, idx = 1
            for it in its {
                switch it.kind {
                case .distance: out += String(format: "    %2d.  length   %.3f m\n", idx, it.value / 1000); sLen += it.value / 1000; idx += 1
                case .area:     out += String(format: "    %2d.  area     %.2f m²\n", idx, it.value); sArea += it.value; idx += 1
                case .count:    sCount += 1
                }
            }
            if sCount > 0 { out += String(format: "    count: %d ea\n", sCount) }
            out += String(format: "    — subtotal:  %.3f m   %.2f m²   %d ea\n\n", sLen, sArea, sCount)
            gLen += sLen; gArea += sArea; gCount += sCount
        }
        if items.isEmpty { out += "No measurements yet.\nPick Distance, Area or Count mode and measure on the plan.\n\n" }
        out += String(format: "TOTAL:  %.3f m   •   %.2f m²   •   %d ea", gLen, gArea, gCount)
        return out
    }

    func csv() -> String {
        func esc(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        var rows = ["Set,Type,Value,Unit"]
        for it in items {
            switch it.kind {
            case .distance: rows.append("\(esc(it.set)),Length,\(String(format: "%.3f", it.value / 1000)),m")
            case .area:     rows.append("\(esc(it.set)),Area,\(String(format: "%.3f", it.value)),m2")
            case .count:    rows.append("\(esc(it.set)),Count,1,ea")
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

// MARK: - Windows ------------------------------------------------------------

final class RulerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayWindow: NSWindow {
    var interactive = false
    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

// MARK: - Ruler view ---------------------------------------------------------

final class RulerView: NSView {
    enum Orientation { case horizontal, vertical }
    var orientation: Orientation = .horizontal { didSet { needsDisplay = true } }
    var collapsed: Bool = false { didSet { needsDisplay = true } }
    var onDoubleClick: (() -> Void)?

    private let handleSize: CGFloat = 18
    private enum DragMode { case none, move, resizeStart, resizeEnd }
    private var dragMode: DragMode = .none
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }

    var currentSpanPoints: CGFloat { orientation == .horizontal ? bounds.width : bounds.height }

    override func draw(_ dirtyRect: NSRect) {
        if collapsed { drawCollapsed(); return }
        let b = bounds
        let bg = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 0.98, alpha: 0.92).setFill(); bg.fill()
        NSColor(calibratedWhite: 0.40, alpha: 0.9).setStroke(); bg.lineWidth = 1; bg.stroke()
        drawTicks(); drawHandles(); drawReadout()
    }

    private func drawCollapsed() {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.95, alpha: 0.95).setFill(); bg.fill()
        let s = NSAttributedString(string: "\(RulerModel.shared.scaleLabel)  ⤢", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
        let sz = s.size()
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }

    private func niceTickMM(targetPoints: CGFloat) -> Double {
        let targetMM = Double(targetPoints) * RulerModel.shared.mmPerPoint
        let candidates: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500,
                                    1000, 2000, 2500, 5000, 10000, 20000, 50000, 100000]
        for c in candidates where c >= targetMM { return c }
        return candidates.last!
    }

    private func labelString(_ mm: Double) -> String {
        if mm == 0 { return "0" }
        if mm >= 1000 {
            let m = mm / 1000.0
            return String(format: m == m.rounded() ? "%.0fm" : "%.2fm", m)
        }
        return String(format: "%.0f", mm)
    }

    private func drawTicks() {
        let model = RulerModel.shared
        let horiz = orientation == .horizontal
        let lengthPts = horiz ? bounds.width : bounds.height
        let majorMM = niceTickMM(targetPoints: 70)
        let stepPts = CGFloat(majorMM / model.mmPerPoint)
        guard stepPts > 3 else { return }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black]

        NSColor(calibratedWhite: 0.5, alpha: 0.8).setStroke()
        let minorStep = stepPts / 5.0
        if minorStep > 1.5 {
            var m: CGFloat = 0
            while m <= lengthPts + 0.5 {
                let p = NSBezierPath(); let t: CGFloat = 7
                if horiz {
                    p.move(to: NSPoint(x: m, y: bounds.height)); p.line(to: NSPoint(x: m, y: bounds.height - t))
                    p.move(to: NSPoint(x: m, y: 0));            p.line(to: NSPoint(x: m, y: t))
                } else {
                    p.move(to: NSPoint(x: 0, y: m));            p.line(to: NSPoint(x: t, y: m))
                    p.move(to: NSPoint(x: bounds.width, y: m)); p.line(to: NSPoint(x: bounds.width - t, y: m))
                }
                p.lineWidth = 0.5; p.stroke(); m += minorStep
            }
        }

        NSColor(calibratedWhite: 0.15, alpha: 0.95).setStroke()
        var i = 0; var d: CGFloat = 0
        while d <= lengthPts + 0.5 {
            let p = NSBezierPath(); let t: CGFloat = 14
            if horiz {
                p.move(to: NSPoint(x: d, y: bounds.height)); p.line(to: NSPoint(x: d, y: bounds.height - t))
                p.move(to: NSPoint(x: d, y: 0));            p.line(to: NSPoint(x: d, y: t))
            } else {
                p.move(to: NSPoint(x: 0, y: d));            p.line(to: NSPoint(x: t, y: d))
                p.move(to: NSPoint(x: bounds.width, y: d)); p.line(to: NSPoint(x: bounds.width - t, y: d))
            }
            p.lineWidth = 1; p.stroke()
            let s = NSAttributedString(string: labelString(Double(i) * majorMM), attributes: textAttrs)
            let sz = s.size()
            if horiz {
                s.draw(at: NSPoint(x: min(d + 2, bounds.width - sz.width - 2), y: bounds.height - t - sz.height - 1))
            } else {
                s.draw(at: NSPoint(x: bounds.width - t - sz.width - 1, y: min(d + 2, bounds.height - sz.height - 2)))
            }
            i += 1; d += stepPts
        }
    }

    private func drawHandles() {
        NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.95, alpha: 0.9).setFill()
        if orientation == .horizontal {
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: handleSize, height: bounds.height), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - handleSize, y: 0, width: handleSize, height: bounds.height), xRadius: 6, yRadius: 6).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: handleSize), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.height - handleSize, width: bounds.width, height: handleSize), xRadius: 6, yRadius: 6).fill()
        }
    }

    private func drawReadout() {
        let model = RulerModel.shared
        let horiz = orientation == .horizontal
        let lengthPts = horiz ? bounds.width : bounds.height
        let bgw = NSColor(calibratedWhite: 1, alpha: 0.7)
        let mainColor: NSColor = model.calibrated
            ? NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.1, alpha: 1)   // calibrated = green
            : NSColor.black                                                    // nominal preset
        let line1 = NSAttributedString(string: model.formatted(points: lengthPts), attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: mainColor, .backgroundColor: bgw])
        let line2 = NSAttributedString(string: model.scaleLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray, .backgroundColor: bgw])
        let s1 = line1.size(), s2 = line2.size()
        let gap: CGFloat = 1
        let totalH = s1.height + gap + s2.height

        if horiz {
            let cx = bounds.midX, cy = bounds.midY
            line1.draw(at: NSPoint(x: cx - s1.width / 2, y: cy + totalH / 2 - s1.height))
            line2.draw(at: NSPoint(x: cx - s2.width / 2, y: cy + totalH / 2 - s1.height - gap - s2.height))
        } else {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState(); ctx.translateBy(x: bounds.midX, y: bounds.midY); ctx.rotate(by: .pi / 2)
            line1.draw(at: NSPoint(x: -s1.width / 2, y: totalH / 2 - s1.height))
            line2.draw(at: NSPoint(x: -s2.width / 2, y: totalH / 2 - s1.height - gap - s2.height))
            ctx.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { dragMode = .none; onDoubleClick?(); return }
        guard let win = window else { return }
        initialMouse = NSEvent.mouseLocation
        initialFrame = win.frame
        if collapsed { dragMode = .move; return }
        let p = convert(event.locationInWindow, from: nil)
        let len = orientation == .horizontal ? bounds.width : bounds.height
        let pos = orientation == .horizontal ? p.x : p.y
        if pos <= handleSize { dragMode = .resizeStart }
        else if pos >= len - handleSize { dragMode = .resizeEnd }
        else { dragMode = .move }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, dragMode != .none else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - initialMouse.x, dy = now.y - initialMouse.y
        let minLen: CGFloat = 90
        var f = initialFrame
        switch dragMode {
        case .move:
            f.origin.x = initialFrame.origin.x + dx; f.origin.y = initialFrame.origin.y + dy
        case .resizeStart:
            if orientation == .horizontal {
                let w = max(minLen, initialFrame.width - dx)
                f.origin.x = initialFrame.origin.x + (initialFrame.width - w); f.size.width = w
            } else {
                let h = max(minLen, initialFrame.height - dy)
                f.origin.y = initialFrame.origin.y + (initialFrame.height - h); f.size.height = h
            }
        case .resizeEnd:
            if orientation == .horizontal { f.size.width = max(minLen, initialFrame.width + dx) }
            else { f.size.height = max(minLen, initialFrame.height + dy) }
        case .none: break
        }
        win.setFrame(f, display: true)
        RulerModel.shared.notify()
    }

    override func mouseUp(with event: NSEvent) { dragMode = .none }
}

// MARK: - Overlay (lead lines, cursor guide, distance & area modes) ----------

final class OverlayView: NSView {
    weak var rulerWindow: NSWindow?
    weak var rulerView: RulerView?
    var originOffset: NSPoint = .zero
    var cursorScreen: NSPoint = .zero
    var pts: [NSPoint] = []          // screen-coord points for distance/area
    var areaClosed = false
    var countMarkers: [NSPoint] = [] // screen-coord markers for count mode
    var onExit: (() -> Void)?        // leave measure mode → back to ruler
    var onCycle: (() -> Void)?       // rotate to the next measure mode

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private func toView(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x - originOffset.x, y: p.y - originOffset.y) }
    private func screenPoint(_ e: NSEvent) -> NSPoint {
        NSPoint(x: originOffset.x + e.locationInWindow.x, y: originOffset.y + e.locationInWindow.y)
    }

    override func mouseDown(with e: NSEvent) {
        let mode = RulerModel.shared.mode
        guard mode != .ruler else { return }
        let p = screenPoint(e)
        switch mode {
        case .count:
            countMarkers.append(p)
            TakeoffStore.shared.add(.count, 1)
        case .distance:
            if pts.count == 1 {                    // second click → commit this length
                let a = pts[0]
                let dist = CGFloat(hypot(Double(p.x - a.x), Double(p.y - a.y)))
                let mm = RulerModel.shared.realMM(points: dist)
                if mm > 0 { TakeoffStore.shared.add(.distance, mm) }
                pts.removeAll()
            } else {                               // first click → drop the start point
                pts = [p]
            }
        case .area:
            if e.clickCount >= 2 { if pts.count >= 3 { commitArea() } else { pts.removeAll() }; needsDisplay = true; return }
            pts.append(p)
        case .ruler:
            break
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { cursorScreen = NSEvent.mouseLocation; needsDisplay = true }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53:                                                                        // Esc: clear current, else exit to ruler
            if !pts.isEmpty || !countMarkers.isEmpty { pts.removeAll(); countMarkers.removeAll(); needsDisplay = true }
            else { onExit?() }
        case 48:                                                                        // Tab: cycle modes
            onCycle?()
        case 36, 76:                                                                    // Return/Enter: close + commit area
            if RulerModel.shared.mode == .area && pts.count >= 3 { commitArea(); needsDisplay = true }
        default: super.keyDown(with: e)
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        if RulerModel.shared.mode != .ruler { onExit?() } else { super.rightMouseDown(with: e) }
    }

    private func commitArea() {
        let aPts = OverlayView.polygonArea(pts)
        let mpp = RulerModel.shared.mmPerPoint
        let m2 = Double(aPts) * mpp * mpp / 1_000_000.0
        if m2 > 0 { TakeoffStore.shared.add(.area, m2) }
        pts.removeAll(); areaClosed = false
    }

    func distanceText() -> String? {
        guard let a = pts.last else { return nil }
        let b = cursorScreen
        let dist = CGFloat(hypot(Double(b.x - a.x), Double(b.y - a.y)))
        let ang = atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / Double.pi
        return "\(RulerModel.shared.formatted(points: dist))  \(String(format: "%.1f°", abs(ang)))"
    }

    func areaText() -> String? {
        let poly = pts
        guard poly.count >= 3 else { return nil }
        let aPts = OverlayView.polygonArea(poly)
        let mpp = RulerModel.shared.mmPerPoint
        let m2 = Double(aPts) * mpp * mpp / 1_000_000.0
        return String(format: "%.2f m²", m2)
    }

    static func polygonArea(_ p: [NSPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<p.count { let j = (i + 1) % p.count; s += p[i].x * p[j].y - p[j].x * p[i].y }
        return abs(s) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rw = rulerWindow, let rv = rulerView else { return }
        switch RulerModel.shared.mode {
        case .ruler:    drawRulerGuides(rw, rv)
        case .distance: drawDistance()
        case .area:     drawArea()
        case .count:    drawCount()
        }
    }

    private func label(_ text: String, at p: NSPoint, color: NSColor) {
        let s = NSAttributedString(string: " \(text) ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white, .backgroundColor: color])
        let sz = s.size()
        var lx = p.x + 8, ly = p.y + 8
        lx = min(max(2, lx), bounds.width - sz.width - 2)
        ly = min(max(2, ly), bounds.height - sz.height - 2)
        s.draw(at: NSPoint(x: lx, y: ly))
    }

    private func dot(_ p: NSPoint, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    }

    private func drawRulerGuides(_ rw: NSWindow, _ rv: RulerView) {
        guard !rv.collapsed else { return }
        let rf = rw.frame
        let horiz = rv.orientation == .horizontal
        let model = RulerModel.shared

        if model.showLeadLines {
            NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.95, alpha: 0.5).setStroke()
            let ext: CGFloat = 240
            let wl = NSBezierPath(); wl.lineWidth = 1
            if horiz {
                for x in [rf.minX, rf.maxX] {
                    wl.move(to: toView(NSPoint(x: x, y: rf.minY - ext))); wl.line(to: toView(NSPoint(x: x, y: rf.maxY + ext)))
                }
            } else {
                for y in [rf.minY, rf.maxY] {
                    wl.move(to: toView(NSPoint(x: rf.minX - ext, y: y))); wl.line(to: toView(NSPoint(x: rf.maxX + ext, y: y)))
                }
            }
            wl.stroke()
        }

        guard model.showGuide else { return }
        let c = toView(cursorScreen)
        let red = NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 0.9)
        red.setStroke()
        let guide = NSBezierPath(); guide.lineWidth = 1
        let distPoints: CGFloat
        if horiz {
            distPoints = cursorScreen.x - rf.minX
            let baseY = toView(NSPoint(x: 0, y: rf.midY)).y
            guide.move(to: NSPoint(x: c.x, y: baseY)); guide.line(to: NSPoint(x: c.x, y: c.y))
        } else {
            distPoints = cursorScreen.y - rf.minY
            let baseX = toView(NSPoint(x: rf.midX, y: 0)).x
            guide.move(to: NSPoint(x: baseX, y: c.y)); guide.line(to: NSPoint(x: c.x, y: c.y))
        }
        guide.stroke()
        dot(c, red)
        label(model.formatted(points: abs(distPoints)), at: c, color: red)
    }

    private func drawDistance() {
        let red = NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 0.95)
        guard let a = pts.last else {
            label("Click two points to measure  ·  Tab cycles  ·  Esc / right-click exits", at: toView(cursorScreen), color: red)
            return
        }
        red.setStroke()
        let av = toView(a), bv = toView(cursorScreen)
        let line = NSBezierPath(); line.lineWidth = 1.5
        line.move(to: av); line.line(to: bv); line.stroke()
        dot(av, red); dot(bv, red)
        let mid = NSPoint(x: (av.x + bv.x) / 2, y: (av.y + bv.y) / 2)
        if let t = distanceText() { label(t, at: mid, color: red) }
    }

    private func drawCount() {
        let purple = NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.72, alpha: 0.95)
        if countMarkers.isEmpty {
            label("Click to count into “\(TakeoffStore.shared.activeSet)”  ·  Tab cycles  ·  Esc / right-click exits", at: toView(cursorScreen), color: purple)
        }
        for (i, m) in countMarkers.enumerated() {
            let v = toView(m)
            purple.setFill()
            NSBezierPath(ovalIn: NSRect(x: v.x - 9, y: v.y - 9, width: 18, height: 18)).fill()
            let s = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: v.x - sz.width / 2, y: v.y - sz.height / 2))
        }
    }

    private func drawArea() {
        guard !pts.isEmpty else {
            label("Click corners; double-click/Enter to close  ·  Tab cycles  ·  Esc / right-click exits", at: toView(cursorScreen),
                  color: NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.85, alpha: 0.9))
            return
        }
        let blue = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.95)
        var verts = pts
        if !areaClosed { verts.append(cursorScreen) }
        let vv = verts.map { toView($0) }

        let path = NSBezierPath()
        path.move(to: vv[0])
        for p in vv.dropFirst() { path.line(to: p) }
        if areaClosed { path.close() }

        NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.15).setFill()
        if areaClosed { path.fill() }
        blue.setStroke(); path.lineWidth = 1.5; path.stroke()
        for p in pts.map({ toView($0) }) { dot(p, blue) }

        if verts.count >= 3 {
            let cx = vv.reduce(0) { $0 + $1.x } / CGFloat(vv.count)
            let cy = vv.reduce(0) { $0 + $1.y } / CGFloat(vv.count)
            if let t = areaText() { label(t, at: NSPoint(x: cx, y: cy), color: blue) }
        }
    }
}

// MARK: - App delegate -------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var rulerWindow: RulerPanel!
    var rulerView: RulerView!
    var overlayWindow: OverlayWindow!
    var overlayView: OverlayView!
    var panel: NSPanel!
    var calibLabel: NSTextField!
    var statusItem: NSStatusItem!

    var takeoffWindow: NSPanel!
    var takeoffTextView: NSTextView!
    var takeoffSetLabel: NSTextField!

    var guideMenuItem, leadMenuItem, collapseMenuItem: NSMenuItem?
    var guideStatusItem, leadStatusItem, collapseStatusItem: NSMenuItem?
    var guideCheckbox, leadCheckbox: NSButton?
    var modeRulerMenu, modeDistMenu, modeAreaMenu, modeCountMenu: NSMenuItem?
    var modeRulerStatus, modeDistStatus, modeAreaStatus, modeCountStatus: NSMenuItem?

    private var globalMon: Any?
    private var localMon: Any?

    private var collapsed = false
    private var savedFrame: NSRect = .zero
    private var savedOrientation: RulerView.Orientation = .horizontal

    private var pendingFrame: NSRect?
    private var pendingVertical = false
    private var hadSavedScale = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadDefaults()
        buildMenu()
        buildRuler()
        if !hadSavedScale { applyDefaultScale() }
        buildOverlay()
        buildControlPanel()
        buildStatusItem()
        RulerModel.shared.onChange = { [weak self] in
            self?.rulerView.needsDisplay = true
            self?.overlayView.needsDisplay = true
            self?.updateCalibLabel()
        }
        TakeoffStore.shared.load()
        TakeoffStore.shared.onChange = { [weak self] in self?.refreshTakeoff() }
        startTracking()
        updateCalibLabel()
        syncToggleStates()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { saveDefaults() }

    private var rulerScreen: NSScreen? { rulerWindow?.screen ?? NSScreen.main }

    // ---- keep windows reachable across display changes --------------------

    /// True if the window's centre sits on some currently-connected screen.
    private func isReachable(_ frame: NSRect) -> Bool {
        let c = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.contains { $0.visibleFrame.contains(c) }
    }

    /// Re-home a frame near the top-left of the main display, keeping its size.
    private func placeOnMain(_ frame: NSRect) -> NSRect {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = frame
        f.size.width = min(f.size.width, vf.width - 80)
        f.size.height = min(f.size.height, vf.height - 80)
        f.origin = NSPoint(x: vf.minX + 80, y: vf.maxY - f.size.height - 100)
        return f
    }

    @objc private func screensChanged() {
        guard rulerWindow != nil, overlayWindow != nil else { return }
        // resize the full-screen overlay to the new display layout
        var union = NSRect.zero
        for s in NSScreen.screens { union = (union == .zero) ? s.frame : union.union(s.frame) }
        if union != .zero {
            overlayWindow.setFrame(union, display: false)
            overlayView.frame = NSRect(origin: .zero, size: union.size)
            overlayView.originOffset = union.origin
        }
        // bring the ruler back onto a visible screen if it's stranded
        if collapsed {
            if !isReachable(savedFrame) { savedFrame = placeOnMain(savedFrame) }
            if !isReachable(rulerWindow.frame) { rulerWindow.setFrame(placeOnMain(rulerWindow.frame), display: true) }
        } else if !isReachable(rulerWindow.frame) {
            rulerWindow.setFrame(placeOnMain(rulerWindow.frame), display: true)
            saveDefaults()
        }
        overlayView.needsDisplay = true
    }

    private func applyDefaultScale() {
        RulerModel.shared.mmPerPoint = 100 * physMMPerPoint(for: rulerScreen)
        RulerModel.shared.scaleRatio = 100
        RulerModel.shared.calibrated = false
    }

    // ---- persistence ------------------------------------------------------

    private func loadDefaults() {
        let d = UserDefaults.standard
        let m = RulerModel.shared
        if d.object(forKey: "displayOverride") != nil {
            let v = d.double(forKey: "displayOverride"); if v > 0 { displayOverrideMMPerPoint = v }
        }
        if d.object(forKey: "mmPerPoint") != nil { m.mmPerPoint = d.double(forKey: "mmPerPoint"); hadSavedScale = true }
        if d.object(forKey: "scaleRatio") != nil { m.scaleRatio = d.double(forKey: "scaleRatio") }
        m.useMetres = d.bool(forKey: "useMetres")
        m.showGuide = d.object(forKey: "showGuide") != nil ? d.bool(forKey: "showGuide") : true
        m.showLeadLines = d.object(forKey: "showLeadLines") != nil ? d.bool(forKey: "showLeadLines") : true
        m.calibrated = d.bool(forKey: "calibrated")
        pendingVertical = d.bool(forKey: "vertical")
        if let s = d.string(forKey: "rulerFrame") {
            let r = NSRectFromString(s); if r.width > 10 && r.height > 10 { pendingFrame = r }
        }
    }

    private func saveDefaults() {
        let d = UserDefaults.standard
        let m = RulerModel.shared
        d.set(m.mmPerPoint, forKey: "mmPerPoint")
        d.set(m.scaleRatio, forKey: "scaleRatio")
        d.set(m.useMetres, forKey: "useMetres")
        d.set(m.showGuide, forKey: "showGuide")
        d.set(m.showLeadLines, forKey: "showLeadLines")
        d.set(m.calibrated, forKey: "calibrated")
        d.set(rulerView.orientation == .vertical, forKey: "vertical")
        if let o = displayOverrideMMPerPoint { d.set(o, forKey: "displayOverride") }
        let fr = collapsed ? savedFrame : rulerWindow.frame
        d.set(NSStringFromRect(fr), forKey: "rulerFrame")
    }

    // ---- windows ----------------------------------------------------------

    private func buildRuler() {
        var frame = NSRect(x: 240, y: 420, width: 620, height: 56)
        if let f = pendingFrame { frame = f }
        if !isReachable(frame) { frame = placeOnMain(frame) }   // saved spot on a now-disconnected display? bring it home
        rulerWindow = RulerPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        rulerWindow.isFloatingPanel = true
        rulerWindow.level = .floating
        rulerWindow.hidesOnDeactivate = false
        rulerWindow.backgroundColor = .clear
        rulerWindow.isOpaque = false
        rulerWindow.hasShadow = true
        rulerWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        rulerView = RulerView(frame: NSRect(origin: .zero, size: frame.size))
        rulerView.orientation = pendingVertical ? .vertical : .horizontal
        rulerView.onDoubleClick = { [weak self] in self?.toggleCollapse() }
        rulerWindow.contentView = rulerView
        rulerWindow.makeKeyAndOrderFront(nil)
    }

    private func buildOverlay() {
        var union = NSRect.zero
        for s in NSScreen.screens { union = (union == .zero) ? s.frame : union.union(s.frame) }
        if union == .zero { union = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

        overlayWindow = OverlayWindow(contentRect: union, styleMask: [.borderless], backing: .buffered, defer: false)
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.acceptsMouseMovedEvents = true
        overlayWindow.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        overlayView = OverlayView(frame: NSRect(origin: .zero, size: union.size))
        overlayView.rulerWindow = rulerWindow
        overlayView.rulerView = rulerView
        overlayView.originOffset = union.origin
        overlayView.cursorScreen = NSEvent.mouseLocation
        overlayView.onExit = { [weak self] in self?.setMode(.ruler) }
        overlayView.onCycle = { [weak self] in self?.cycleMode() }
        overlayWindow.contentView = overlayView
        overlayWindow.orderFront(nil)
    }

    private func startTracking() {
        globalMon = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.overlayView.cursorScreen = NSEvent.mouseLocation
            self?.overlayView.needsDisplay = true
        }
        localMon = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] e in
            self?.overlayView.cursorScreen = NSEvent.mouseLocation
            self?.overlayView.needsDisplay = true
            return e
        }
    }

    // ---- control panel ----------------------------------------------------

    private func buildControlPanel() {
        let frame = NSRect(x: 240, y: 100, width: 300, height: 384)
        panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Desktop Scale Ruler"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel); b.bezelStyle = .rounded; return b
        }

        let calibrateBtn = button("Calibrate to known dimension…", #selector(calibrate))
        let dispBtn = button("Calibrate display (once)…", #selector(calibrateDisplay))
        let row100 = button("1:100", #selector(scale100))
        let row50  = button("1:50",  #selector(scale50))
        let custom = button("Custom 1:n…", #selector(customScale))
        let orient = button("Rotate ↔ / ↕", #selector(toggleOrientation))
        let units  = button("mm / m", #selector(toggleUnits))
        let minBtn = button("Minimise ruler", #selector(toggleCollapse))
        let mRuler = button("Ruler", #selector(modeRuler))
        let mDist  = button("Distance", #selector(modeDistance))
        let mArea  = button("Area", #selector(modeArea))
        let mCount = button("Count", #selector(modeCount))
        let takeoffBtn = button("Takeoff list…", #selector(showTakeoff))

        guideCheckbox = NSButton(checkboxWithTitle: "Cursor guide", target: self, action: #selector(toggleGuide))
        leadCheckbox  = NSButton(checkboxWithTitle: "Lead lines",  target: self, action: #selector(toggleLeadLines))

        func hrow(_ vs: [NSView]) -> NSStackView {
            let r = NSStackView(views: vs); r.orientation = .horizontal; r.distribution = .fillEqually; r.spacing = 6; return r
        }

        calibLabel = NSTextField(labelWithString: "")
        calibLabel.font = NSFont.systemFont(ofSize: 11)
        calibLabel.textColor = .secondaryLabelColor
        calibLabel.alignment = .center
        calibLabel.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(wrappingLabelWithString:
            "Distance/Area/Count capture clicks — Esc ends the current run; switch to Ruler to give the screen back. New measurements drop into the active takeoff set. Open the Takeoff list to name sets, see totals and export CSV.")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 268
        hint.widthAnchor.constraint(equalToConstant: 268).isActive = true
        calibLabel.widthAnchor.constraint(equalToConstant: 268).isActive = true

        let stack = NSStackView(views: [
            calibrateBtn, dispBtn,
            hrow([row100, row50, custom]),
            hrow([mRuler, mDist, mArea, mCount]),
            hrow([orient, units]),
            hrow([guideCheckbox!, leadCheckbox!]),
            takeoffBtn, minBtn, calibLabel, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        panel.makeKeyAndOrderFront(nil)
    }

    private func updateCalibLabel() {
        let m = RulerModel.shared
        let tag = m.calibrated ? "calibrated" : "preset"
        calibLabel?.stringValue = String(format: "1 pt = %.2f mm  •  ≈ 1:%.0f  •  %@", m.mmPerPoint, m.scaleRatio, tag)
    }

    // ---- status-bar item --------------------------------------------------

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "ruler", accessibilityDescription: "Desktop Scale Ruler") { btn.image = img }
            else { btn.title = "📏" }
        }
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; menu.addItem(it); return it
        }
        modeRulerStatus = add("Mode: Ruler", #selector(modeRuler))
        modeDistStatus  = add("Mode: Distance (2 points)", #selector(modeDistance))
        modeAreaStatus  = add("Mode: Area", #selector(modeArea))
        modeCountStatus = add("Mode: Count (tally)", #selector(modeCount))
        menu.addItem(.separator())
        _ = add("Show Takeoff List", #selector(showTakeoff))
        _ = add("New Takeoff Set…", #selector(newTakeoffSet))
        _ = add("Export Takeoff CSV…", #selector(exportTakeoffCSV))
        menu.addItem(.separator())
        _ = add("Calibrate to Known Dimension…", #selector(calibrate))
        _ = add("Calibrate Display (once)…", #selector(calibrateDisplay))
        _ = add("Scale 1:100", #selector(scale100))
        _ = add("Scale 1:50", #selector(scale50))
        _ = add("Custom Scale…", #selector(customScale))
        menu.addItem(.separator())
        _ = add("Rotate Horizontal / Vertical", #selector(toggleOrientation))
        _ = add("Toggle mm / m", #selector(toggleUnits))
        _ = add("Copy Measurement", #selector(copyMeasurement))
        guideStatusItem = add("Cursor Guide", #selector(toggleGuide))
        leadStatusItem = add("Lead Lines", #selector(toggleLeadLines))
        collapseStatusItem = add("Minimise Ruler", #selector(toggleCollapse))
        menu.addItem(.separator())
        _ = add("Show Controls Window", #selector(showControls))
        let quit = NSMenuItem(title: "Quit Desktop Scale Ruler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // ---- input prompt -----------------------------------------------------

    private func promptForNumber(title: String, message: String, placeholder: String) -> Double? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.placeholderString = placeholder
        alert.accessoryView = tf
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let raw = tf.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(raw), v > 0 else { return nil }
        return v
    }

    // ---- actions ----------------------------------------------------------

    @objc private func calibrate() {
        if collapsed { toggleCollapse() }
        let span = rulerView.currentSpanPoints
        guard span > 0 else { return }
        guard let mm = promptForNumber(
            title: "Calibrate to a known dimension",
            message: "The ruler currently spans \(Int(span)) screen points. Enter the real-world length it covers, in millimetres.",
            placeholder: "e.g. 3000") else { return }
        let m = RulerModel.shared
        m.mmPerPoint = mm / Double(span)
        m.scaleRatio = m.mmPerPoint / physMMPerPoint(for: rulerScreen)
        m.calibrated = true
        m.notify(); saveDefaults()
    }

    @objc private func calibrateDisplay() {
        if collapsed { toggleCollapse() }
        let span = rulerView.currentSpanPoints
        guard span > 0 else { return }
        guard let mm = promptForNumber(
            title: "Calibrate this display (once)",
            message: "Hold a physical ruler or card against the screen. Stretch the on-screen ruler to a known PHYSICAL length, then enter that length in mm (a credit card is 85.6 mm wide).",
            placeholder: "e.g. 85.6") else { return }
        displayOverrideMMPerPoint = mm / Double(span)
        let m = RulerModel.shared
        if m.calibrated { m.scaleRatio = m.mmPerPoint / physMMPerPoint(for: rulerScreen) }
        else { setNominalScale(m.scaleRatio) }
        m.notify(); saveDefaults()
    }

    private func setNominalScale(_ s: Double) {
        let m = RulerModel.shared
        m.scaleRatio = s
        m.mmPerPoint = s * physMMPerPoint(for: rulerScreen)
        m.calibrated = false
        m.notify(); saveDefaults()
    }

    @objc private func scale100() { setNominalScale(100) }
    @objc private func scale50()  { setNominalScale(50) }

    @objc private func customScale() {
        guard let s = promptForNumber(
            title: "Custom scale",
            message: "Enter the plan scale ratio (the n in 1:n). Set for Preview's “Actual Size”.",
            placeholder: "e.g. 200") else { return }
        setNominalScale(s)
    }

    @objc private func toggleOrientation() {
        guard !collapsed else { return }
        let f = rulerWindow.frame
        let thickness: CGFloat = 56
        if rulerView.orientation == .horizontal {
            rulerWindow.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: thickness, height: max(160, f.width)), display: true)
            rulerView.orientation = .vertical
        } else {
            rulerWindow.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: max(160, f.height), height: thickness), display: true)
            rulerView.orientation = .horizontal
        }
        RulerModel.shared.notify(); saveDefaults()
    }

    @objc private func toggleUnits() { RulerModel.shared.useMetres.toggle(); RulerModel.shared.notify(); saveDefaults() }

    @objc private func toggleGuide() {
        RulerModel.shared.showGuide.toggle(); syncToggleStates(); overlayView.needsDisplay = true; saveDefaults()
    }
    @objc private func toggleLeadLines() {
        RulerModel.shared.showLeadLines.toggle(); syncToggleStates(); overlayView.needsDisplay = true; saveDefaults()
    }

    @objc private func toggleCollapse() {
        let collapsedSize = NSSize(width: 70, height: 30)
        if collapsed {
            rulerView.collapsed = false
            rulerView.orientation = savedOrientation
            rulerWindow.setFrame(savedFrame, display: true)
            collapsed = false
        } else {
            savedFrame = rulerWindow.frame
            savedOrientation = rulerView.orientation
            let f = rulerWindow.frame
            rulerView.collapsed = true
            rulerWindow.setFrame(NSRect(origin: NSPoint(x: f.minX, y: f.maxY - collapsedSize.height), size: collapsedSize), display: true)
            collapsed = true
        }
        syncToggleStates(); overlayView.needsDisplay = true
    }

    @objc private func showControls() { panel.makeKeyAndOrderFront(nil) }

    // ---- takeoff ----------------------------------------------------------

    private func promptForString(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = placeholder
        alert.accessoryView = tf
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return tf.stringValue
    }

    private func buildTakeoffWindow() {
        let frame = NSRect(x: 560, y: 140, width: 380, height: 470)
        takeoffWindow = NSPanel(contentRect: frame,
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
        takeoffWindow.title = "Takeoff List"
        takeoffWindow.isFloatingPanel = true
        takeoffWindow.level = .floating
        takeoffWindow.hidesOnDeactivate = false
        takeoffWindow.isReleasedWhenClosed = false

        let content = takeoffWindow.contentView!

        takeoffSetLabel = NSTextField(labelWithString: "")
        takeoffSetLabel.font = NSFont.boldSystemFont(ofSize: 12)
        takeoffSetLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        takeoffTextView = NSTextView()
        takeoffTextView.isEditable = false
        takeoffTextView.isRichText = false
        takeoffTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        takeoffTextView.textContainerInset = NSSize(width: 6, height: 6)
        takeoffTextView.isVerticallyResizable = true
        takeoffTextView.isHorizontallyResizable = false
        takeoffTextView.autoresizingMask = [.width]
        takeoffTextView.minSize = NSSize(width: 0, height: 0)
        takeoffTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        takeoffTextView.textContainer?.widthTracksTextView = true
        scroll.documentView = takeoffTextView

        func btn(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; return b
        }
        func hrow(_ vs: [NSView]) -> NSStackView {
            let r = NSStackView(views: vs); r.orientation = .horizontal; r.distribution = .fillEqually; r.spacing = 6
            r.translatesAutoresizingMaskIntoConstraints = false; return r
        }
        let row1 = hrow([btn("New set…", #selector(newTakeoffSet)), btn("Undo", #selector(undoTakeoff)), btn("Clear", #selector(clearTakeoff))])
        let row2 = hrow([btn("Export CSV…", #selector(exportTakeoffCSV)), btn("Copy", #selector(copyTakeoff))])

        content.addSubview(takeoffSetLabel)
        content.addSubview(scroll)
        content.addSubview(row1)
        content.addSubview(row2)
        let pad: CGFloat = 12
        NSLayoutConstraint.activate([
            takeoffSetLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            takeoffSetLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            takeoffSetLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            scroll.topAnchor.constraint(equalTo: takeoffSetLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            row1.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            row1.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            row1.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 6),
            row2.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            row2.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            row2.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad)
        ])
    }

    private func refreshTakeoff() {
        guard takeoffTextView != nil else { return }
        takeoffSetLabel.stringValue = "Active set:  \(TakeoffStore.shared.activeSet)"
        takeoffTextView.string = TakeoffStore.shared.summaryText()
    }

    @objc private func showTakeoff() {
        if takeoffWindow == nil { buildTakeoffWindow() }
        refreshTakeoff()
        takeoffWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func newTakeoffSet() {
        guard let raw = promptForString(title: "New takeoff set",
                                        message: "Name this set (e.g. Ground floor walls, Footings, Slab). New measurements go into it.",
                                        placeholder: "Set name") else { return }
        let name = raw.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { TakeoffStore.shared.newSet(name) }
    }

    @objc private func undoTakeoff() { TakeoffStore.shared.undoLast() }

    @objc private func clearTakeoff() {
        let a = NSAlert()
        a.messageText = "Clear all takeoff items?"
        a.informativeText = "This removes every measurement from every set. It can't be undone."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { TakeoffStore.shared.clearAll() }
    }

    @objc private func exportTakeoffCSV() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "takeoff.csv"
        p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let url = p.url {
            try? TakeoffStore.shared.csv().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func copyTakeoff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TakeoffStore.shared.csv(), forType: .string)
    }

    // ---- measure modes ----------------------------------------------------

    private func setMode(_ mode: MeasureMode) {
        RulerModel.shared.mode = mode
        let interactive = (mode != .ruler)
        overlayWindow.ignoresMouseEvents = !interactive
        overlayWindow.interactive = interactive
        overlayView.pts.removeAll(); overlayView.areaClosed = false; overlayView.countMarkers.removeAll()
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            overlayWindow.makeKeyAndOrderFront(nil)
            overlayWindow.makeFirstResponder(overlayView)
        }
        syncToggleStates(); overlayView.needsDisplay = true
    }

    @objc private func modeRuler() { setMode(.ruler) }
    @objc private func modeDistance() { setMode(.distance) }
    @objc private func modeArea() { setMode(.area) }
    @objc private func modeCount() { setMode(.count) }

    @objc private func cycleMode() {
        let next: MeasureMode
        switch RulerModel.shared.mode {
        case .ruler: next = .distance
        case .distance: next = .area
        case .area: next = .count
        case .count: next = .ruler
        }
        setMode(next)
    }

    @objc private func copyMeasurement() {
        let m = RulerModel.shared
        var text = ""
        switch m.mode {
        case .ruler: text = "\(m.formatted(points: rulerView.currentSpanPoints)) (\(m.scaleLabel))"
        case .distance: text = overlayView.distanceText() ?? ""
        case .area: text = overlayView.areaText() ?? ""
        case .count: text = ""
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // ---- sync -------------------------------------------------------------

    private func syncToggleStates() {
        let m = RulerModel.shared
        let g: NSControl.StateValue = m.showGuide ? .on : .off
        let l: NSControl.StateValue = m.showLeadLines ? .on : .off
        guideMenuItem?.state = g; guideStatusItem?.state = g; guideCheckbox?.state = g
        leadMenuItem?.state = l;  leadStatusItem?.state = l;  leadCheckbox?.state = l

        collapseMenuItem?.title = collapsed ? "Expand Ruler" : "Minimise Ruler"
        collapseStatusItem?.title = collapsed ? "Expand Ruler" : "Minimise Ruler"

        func ms(_ on: Bool) -> NSControl.StateValue { on ? .on : .off }
        modeRulerMenu?.state = ms(m.mode == .ruler); modeRulerStatus?.state = ms(m.mode == .ruler)
        modeDistMenu?.state  = ms(m.mode == .distance); modeDistStatus?.state = ms(m.mode == .distance)
        modeAreaMenu?.state  = ms(m.mode == .area); modeAreaStatus?.state = ms(m.mode == .area)
        modeCountMenu?.state = ms(m.mode == .count); modeCountStatus?.state = ms(m.mode == .count)
    }

    // ---- menu -------------------------------------------------------------

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Desktop Scale Ruler", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Desktop Scale Ruler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let rulerItem = NSMenuItem(); main.addItem(rulerItem)
        let rulerMenu = NSMenu(title: "Ruler"); rulerItem.submenu = rulerMenu
        modeRulerMenu = rulerMenu.addItem(withTitle: "Mode: Ruler", action: #selector(modeRuler), keyEquivalent: "b")
        modeDistMenu  = rulerMenu.addItem(withTitle: "Mode: Distance (run)", action: #selector(modeDistance), keyEquivalent: "d")
        modeAreaMenu  = rulerMenu.addItem(withTitle: "Mode: Area", action: #selector(modeArea), keyEquivalent: "e")
        modeCountMenu = rulerMenu.addItem(withTitle: "Mode: Count (tally)", action: #selector(modeCount), keyEquivalent: "")
        rulerMenu.addItem(withTitle: "Cycle Mode (Tab) — Esc / right-click exits", action: #selector(cycleMode), keyEquivalent: "")
        rulerMenu.addItem(.separator())
        rulerMenu.addItem(withTitle: "Show Takeoff List", action: #selector(showTakeoff), keyEquivalent: "t")
        rulerMenu.addItem(withTitle: "New Takeoff Set…", action: #selector(newTakeoffSet), keyEquivalent: "n")
        rulerMenu.addItem(withTitle: "Undo Last Takeoff", action: #selector(undoTakeoff), keyEquivalent: "z")
        rulerMenu.addItem(withTitle: "Export Takeoff CSV…", action: #selector(exportTakeoffCSV), keyEquivalent: "")
        rulerMenu.addItem(.separator())
        rulerMenu.addItem(withTitle: "Calibrate to Known Dimension…", action: #selector(calibrate), keyEquivalent: "k")
        rulerMenu.addItem(withTitle: "Calibrate Display (once)…", action: #selector(calibrateDisplay), keyEquivalent: "K")
        rulerMenu.addItem(withTitle: "Scale 1:100", action: #selector(scale100), keyEquivalent: "1")
        rulerMenu.addItem(withTitle: "Scale 1:50", action: #selector(scale50), keyEquivalent: "2")
        rulerMenu.addItem(withTitle: "Custom Scale…", action: #selector(customScale), keyEquivalent: "0")
        rulerMenu.addItem(.separator())
        rulerMenu.addItem(withTitle: "Copy Measurement", action: #selector(copyMeasurement), keyEquivalent: "c")
        rulerMenu.addItem(withTitle: "Rotate Horizontal / Vertical", action: #selector(toggleOrientation), keyEquivalent: "r")
        rulerMenu.addItem(withTitle: "Toggle mm / m", action: #selector(toggleUnits), keyEquivalent: "u")
        guideMenuItem = rulerMenu.addItem(withTitle: "Cursor Guide", action: #selector(toggleGuide), keyEquivalent: "g")
        leadMenuItem = rulerMenu.addItem(withTitle: "Lead Lines", action: #selector(toggleLeadLines), keyEquivalent: "l")
        collapseMenuItem = rulerMenu.addItem(withTitle: "Minimise Ruler", action: #selector(toggleCollapse), keyEquivalent: "m")
        rulerMenu.addItem(.separator())
        rulerMenu.addItem(withTitle: "Show Controls", action: #selector(showControls), keyEquivalent: ",")

        NSApp.mainMenu = main
    }
}

// MARK: - Launch -------------------------------------------------------------

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
