import Foundation

/// Mirrors the adaptive grid's 80-point minimum, 8-point spacing and 12-point padding.
enum GridNavigation {
    static func columns(for width: CGFloat) -> Int {
        max(1, Int((max(0, width - 24) + 8) / 88))
    }

    static func selectedIndex(items: [URL], selection: Set<URL>, preferred: URL?) -> Int? {
        if let preferred, selection.contains(preferred), let index = items.firstIndex(of: preferred) {
            return index
        }
        return items.firstIndex(where: selection.contains)
    }

    static func nextIndex(current: Int?, offset: Int, count: Int) -> Int {
        guard count > 0, let current else { return 0 }
        let stride = abs(offset)
        if stride > 1 {
            if offset < 0 && current < stride { return current }
            if offset > 0 && current / stride == (count - 1) / stride { return current }
        }
        return max(0, min(count - 1, current + offset))
    }
}
