import AppKit
import SwiftUI

/// Thread-safe cache for rasterized SVG images shared across toolbar icons,
/// sidebar glyphs, remote host marks, and known-sender avatar tiles.
final class SVGIconCache {
    static let shared = SVGIconCache()

    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func templateImage(svg: String) -> NSImage? {
        cached(key: "tpl:\(svg)") {
            guard let data = svg.data(using: .utf8), let img = NSImage(data: data) else {
                return nil
            }
            img.isTemplate = true
            return img
        }
    }

    func cached(key: String, make: () -> NSImage?) -> NSImage? {
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let created = make() else { return nil }
        lock.lock()
        cache[key] = created
        lock.unlock()
        return created
    }
}

/// Shared Simple Icons SVG path data reused across brand marks (CC0 1.0).
enum BrandSVGPaths {
    static let github =
        "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
}

/// Phosphor glyphs used across the toolbar, sidebar, inspector, and graph chips.
enum PhosphorGlyph {
    case fetch, pull, push, filter, filterFilled, chevronDown
    case branch, tag, cloud, folder, archive, panelBottom

    /// Optional faded shape drawn under the main path (duotone glyphs).
    fileprivate var shading: String? {
        switch self {
        case .panelBottom: "M208,128v72a8,8,0,0,1-8,8H56a8,8,0,0,1-8-8V128Z"
        default: nil
        }
    }

    fileprivate var path: String {
        switch self {
        case .fetch:
            // phosphor regular/cloud-arrow-down
            "M248,128a87.34,87.34,0,0,1-17.6,52.81,8,8,0,1,1-12.8-9.62A71.34,71.34,0,0,0,232,128a72,72,0,0,0-144,0,8,8,0,0,1-16,0,88,88,0,0,1,3.29-23.88C74.2,104,73.1,104,72,104a48,48,0,0,0,0,96H96a8,8,0,0,1,0,16H72A64,64,0,1,1,81.29,88.68,88,88,0,0,1,248,128Zm-69.66,42.34L160,188.69V128a8,8,0,0,0-16,0v60.69l-18.34-18.35a8,8,0,0,0-11.32,11.32l32,32a8,8,0,0,0,11.32,0l32-32a8,8,0,0,0-11.32-11.32Z"
        case .pull:
            // phosphor regular/arrow-line-down
            "M50.34,117.66a8,8,0,0,1,11.32-11.32L120,164.69V32a8,8,0,0,1,16,0V164.69l58.34-58.35a8,8,0,0,1,11.32,11.32l-72,72a8,8,0,0,1-11.32,0ZM216,208H40a8,8,0,0,0,0,16H216a8,8,0,0,0,0-16Z"
        case .push:
            // phosphor regular/arrow-line-up
            "M205.66,138.34a8,8,0,0,1-11.32,11.32L136,91.31V224a8,8,0,0,1-16,0V91.31L61.66,149.66a8,8,0,0,1-11.32-11.32l72-72a8,8,0,0,1,11.32,0ZM216,32H40a8,8,0,0,0,0,16H216a8,8,0,0,0,0-16Z"
        case .filter:
            // phosphor regular/funnel
            "M230.6,49.53A15.81,15.81,0,0,0,216,40H40A16,16,0,0,0,28.19,66.76l.08.09L96,139.17V216a16,16,0,0,0,24.87,13.32l32-21.34A16,16,0,0,0,160,194.66V139.17l67.74-72.32.08-.09A15.8,15.8,0,0,0,230.6,49.53ZM40,56h0Zm106.18,74.58A8,8,0,0,0,144,136v58.66L112,216V136a8,8,0,0,0-2.16-5.47L40,56H216Z"
        case .filterFilled:
            // phosphor fill/funnel: the outer outline with the interior left solid
            "M230.6,49.53A15.81,15.81,0,0,0,216,40H40A16,16,0,0,0,28.19,66.76l.08.09L96,139.17V216a16,16,0,0,0,24.87,13.32l32-21.34A16,16,0,0,0,160,194.66V139.17l67.74-72.32.08-.09A15.8,15.8,0,0,0,230.6,49.53Z"
        case .chevronDown:
            // phosphor regular/caret-down
            "M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z"
        case .branch:
            "M232,64a32,32,0,1,0-40,31v17a8,8,0,0,1-8,8H96a23.84,23.84,0,0,0-8,1.38V95a32,32,0,1,0-16,0v66a32,32,0,1,0,16,0V144a8,8,0,0,1,8-8h88a24,24,0,0,0,24-24V95A32.06,32.06,0,0,0,232,64ZM64,64A16,16,0,1,1,80,80,16,16,0,0,1,64,64ZM96,192a16,16,0,1,1-16-16A16,16,0,0,1,96,192ZM200,80a16,16,0,1,1,16-16A16,16,0,0,1,200,80Z"
        case .tag:
            "M243.31,136,144,36.69A15.86,15.86,0,0,0,132.69,32H40a8,8,0,0,0-8,8v92.69A15.86,15.86,0,0,0,36.69,144L136,243.31a16,16,0,0,0,22.63,0l84.68-84.68a16,16,0,0,0,0-22.63Zm-96,96L48,132.69V48h84.69L232,147.31ZM96,84A12,12,0,1,1,84,72,12,12,0,0,1,96,84Z"
        case .cloud:
            "M160,40A88.09,88.09,0,0,0,81.29,88.67,64,64,0,1,0,72,216h88a88,88,0,0,0,0-176Zm0,160H72a48,48,0,0,1,0-96c1.1,0,2.2,0,3.29.11A88,88,0,0,0,72,128a8,8,0,0,0,16,0,72,72,0,1,1,72,72Z"
        case .folder:
            "M216,72H131.31L104,44.69A15.86,15.86,0,0,0,92.69,40H40A16,16,0,0,0,24,56V200.62A15.4,15.4,0,0,0,39.38,216H216.89A15.13,15.13,0,0,0,232,200.89V88A16,16,0,0,0,216,72ZM40,56H92.69l16,16H40ZM216,200H40V88H216Z"
        case .panelBottom:
            // Phosphor "square-half-bottom" (duotone): outline plus the shaded half, below.
            "M200,40H56A16,16,0,0,0,40,56V200a16,16,0,0,0,16,16H200a16,16,0,0,0,16-16V56A16,16,0,0,0,200,40Zm0,16v64H56V56Zm0,144H56V136H200v64Z"
        case .archive:
            // phosphor regular/archive
            "M224,48H32A16,16,0,0,0,16,64V88a16,16,0,0,0,16,16v88a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V104a16,16,0,0,0,16-16V64A16,16,0,0,0,224,48ZM208,192H48V104H208ZM224,88H32V64H224V88ZM96,136a8,8,0,0,1,8-8h48a8,8,0,0,1,0,16H104A8,8,0,0,1,96,136Z"
        }
    }

    var svg: String {
        let shade = shading.map { "<path fill=\"black\" opacity=\"0.4\" d=\"\($0)\"/>" } ?? ""
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">\(shade)<path fill=\"black\" d=\"\(path)\"/></svg>"
    }
}

enum ToolbarActionIcon {
    case fetch
    case pull
    case push
    case stash
    case filter
    case filterFilled
    case chevronDown

    fileprivate var glyph: PhosphorGlyph {
        switch self {
        case .fetch: return .fetch
        case .pull: return .pull
        case .push: return .push
        case .stash: return .archive
        case .filter: return .filter
        case .filterFilled: return .filterFilled
        case .chevronDown: return .chevronDown
        }
    }

    fileprivate var size: CGFloat {
        self == .chevronDown ? 9 : 19
    }
}

struct ToolbarIconView: View {
    let icon: ToolbarActionIcon

    var body: some View {
        PhosphorIcon(glyph: icon.glyph, size: icon.size)
            .foregroundStyle(Color.primary.opacity(0.82))
    }
}

/// A Phosphor glyph tinted by the surrounding `foregroundStyle`.
struct PhosphorIcon: View {
    let glyph: PhosphorGlyph
    var size: CGFloat = 13

    /// The glyph as a template image, for AppKit views that cannot host a SwiftUI icon.
    static func nsImage(for glyph: PhosphorGlyph) -> NSImage? {
        SVGIconCache.shared.templateImage(svg: glyph.svg)
    }

    var body: some View {
        if let image = Self.nsImage(for: glyph) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
