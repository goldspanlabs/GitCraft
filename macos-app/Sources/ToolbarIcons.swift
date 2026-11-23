import AppKit
import SwiftUI

enum ToolbarActionIcon {
    case quickLaunch
    case fetch
    case pull
    case push
    case stash
    case chevronDown
}

struct ToolbarIconView: View {
    let icon: ToolbarActionIcon

    var body: some View {
        switch icon {
        case .quickLaunch:
            // phosphor regular/folder
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M216,72H131.31L104,44.69A15.86,15.86,0,0,0,92.69,40H40A16,16,0,0,0,24,56V200.62A15.4,15.4,0,0,0,39.38,216H216.89A15.13,15.13,0,0,0,232,200.89V88A16,16,0,0,0,216,72ZM40,56H92.69l16,16H40ZM216,200H40V88H216Z"/></svg>
            """)
            .frame(width: 19, height: 19)

        case .fetch:
            // phosphor regular/cloud-arrow-down
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M248,128a87.34,87.34,0,0,1-17.6,52.81,8,8,0,1,1-12.8-9.62A71.34,71.34,0,0,0,232,128a72,72,0,0,0-144,0,8,8,0,0,1-16,0,88,88,0,0,1,3.29-23.88C74.2,104,73.1,104,72,104a48,48,0,0,0,0,96H96a8,8,0,0,1,0,16H72A64,64,0,1,1,81.29,88.68,88,88,0,0,1,248,128Zm-69.66,42.34L160,188.69V128a8,8,0,0,0-16,0v60.69l-18.34-18.35a8,8,0,0,0-11.32,11.32l32,32a8,8,0,0,0,11.32,0l32-32a8,8,0,0,0-11.32-11.32Z"/></svg>
            """)
            .frame(width: 19, height: 19)

        case .pull:
            // phosphor regular/arrow-line-down
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M50.34,117.66a8,8,0,0,1,11.32-11.32L120,164.69V32a8,8,0,0,1,16,0V164.69l58.34-58.35a8,8,0,0,1,11.32,11.32l-72,72a8,8,0,0,1-11.32,0ZM216,208H40a8,8,0,0,0,0,16H216a8,8,0,0,0,0-16Z"/></svg>
            """)
            .frame(width: 19, height: 19)

        case .push:
            // phosphor regular/arrow-line-up
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M205.66,138.34a8,8,0,0,1-11.32,11.32L136,91.31V224a8,8,0,0,1-16,0V91.31L61.66,149.66a8,8,0,0,1-11.32-11.32l72-72a8,8,0,0,1,11.32,0ZM216,32H40a8,8,0,0,0,0,16H216a8,8,0,0,0,0-16Z"/></svg>
            """)
            .frame(width: 19, height: 19)

        case .stash:
            // phosphor regular/archive
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M224,48H32A16,16,0,0,0,16,64V88a16,16,0,0,0,16,16v88a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V104a16,16,0,0,0,16-16V64A16,16,0,0,0,224,48ZM208,192H48V104H208ZM224,88H32V64H224V88ZM96,136a8,8,0,0,1,8-8h48a8,8,0,0,1,0,16H104A8,8,0,0,1,96,136Z"/></svg>
            """)
            .frame(width: 19, height: 19)

        case .chevronDown:
            // phosphor regular/caret-down
            SVGIconView(svg: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="black" d="M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z"/></svg>
            """)
            .frame(width: 9, height: 9)
        }
    }
}

private struct SVGIconView: View {
    let svg: String

    private var nsImage: NSImage? {
        SVGIconCache.shared.image(for: svg)
    }

    var body: some View {
        if let nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.primary.opacity(0.82))
        }
    }
}

private final class SVGIconCache {
    static let shared = SVGIconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func image(for svg: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[svg] {
            return existing
        }
        guard let data = svg.data(using: .utf8),
              let img = NSImage(data: data)
        else {
            return nil
        }
        img.isTemplate = true
        cache[svg] = img
        return img
    }
}
