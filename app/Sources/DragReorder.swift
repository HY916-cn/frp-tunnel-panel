import Foundation

enum DragReorder {
    /// 目标行使用少量迟滞，鼠标停在分界线附近时不会在两行之间反复横跳。
    static func targetIndex(
        sourceIndex: Int,
        currentTargetIndex: Int,
        translation: CGFloat,
        rowHeight: CGFloat,
        itemCount: Int,
        hysteresis: CGFloat = 0.08
    ) -> Int {
        guard itemCount > 0, rowHeight > 0 else { return currentTargetIndex }

        let source = min(max(sourceIndex, 0), itemCount - 1)
        var target = min(max(currentTargetIndex, 0), itemCount - 1)
        let margin = rowHeight * hysteresis

        while target < itemCount - 1 {
            let nextBoundary =
                (CGFloat(target - source) + 0.5) * rowHeight + margin
            guard translation >= nextBoundary else { break }
            target += 1
        }

        while target > 0 {
            let previousBoundary =
                (CGFloat(target - source) - 0.5) * rowHeight - margin
            guard translation <= previousBoundary else { break }
            target -= 1
        }

        return target
    }

    /// 拖动行保持在原布局槽位并直接跟随鼠标；途经的其他行只移动一个槽位让路。
    static func displacement(
        for index: Int,
        sourceIndex: Int?,
        targetIndex: Int?,
        rowHeight: CGFloat
    ) -> CGFloat {
        guard
            let sourceIndex,
            let targetIndex,
            index != sourceIndex
        else { return 0 }

        if sourceIndex < targetIndex,
           index > sourceIndex,
           index <= targetIndex {
            return -rowHeight
        }

        if targetIndex < sourceIndex,
           index >= targetIndex,
           index < sourceIndex {
            return rowHeight
        }

        return 0
    }

    static func reordered<T>(
        _ items: [T],
        sourceIndex: Int,
        targetIndex: Int
    ) -> [T] {
        guard
            items.indices.contains(sourceIndex),
            items.indices.contains(targetIndex),
            sourceIndex != targetIndex
        else { return items }

        var result = items
        let moving = result.remove(at: sourceIndex)
        result.insert(moving, at: targetIndex)
        return result
    }
}
