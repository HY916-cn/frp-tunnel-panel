import Foundation

@main
struct DragReorderChecks {
    static func main() {
        let rowHeight: CGFloat = 40

        precondition(
            DragReorder.targetIndex(
                sourceIndex: 2,
                currentTargetIndex: 2,
                translation: 22,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 2
        )
        precondition(
            DragReorder.targetIndex(
                sourceIndex: 2,
                currentTargetIndex: 2,
                translation: 24,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 3
        )
        precondition(
            DragReorder.targetIndex(
                sourceIndex: 2,
                currentTargetIndex: 3,
                translation: 18,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 3
        )
        precondition(
            DragReorder.targetIndex(
                sourceIndex: 2,
                currentTargetIndex: 3,
                translation: 16,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 2
        )

        precondition(
            DragReorder.targetIndex(
                sourceIndex: 1,
                currentTargetIndex: 1,
                translation: 130,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 4
        )
        precondition(
            DragReorder.targetIndex(
                sourceIndex: 4,
                currentTargetIndex: 4,
                translation: -130,
                rowHeight: rowHeight,
                itemCount: 6
            ) == 1
        )

        let down = (0..<5).map {
            DragReorder.displacement(
                for: $0,
                sourceIndex: 1,
                targetIndex: 3,
                rowHeight: rowHeight
            )
        }
        precondition(down == [0, 0, -40, -40, 0])

        let up = (0..<5).map {
            DragReorder.displacement(
                for: $0,
                sourceIndex: 3,
                targetIndex: 1,
                rowHeight: rowHeight
            )
        }
        precondition(up == [0, 40, 40, 0, 0])

        precondition(
            DragReorder.reordered(
                ["a", "b", "c", "d"],
                sourceIndex: 1,
                targetIndex: 3
            ) == ["a", "c", "d", "b"]
        )
        precondition(
            DragReorder.reordered(
                ["a", "b", "c", "d"],
                sourceIndex: 3,
                targetIndex: 1
            ) == ["a", "d", "b", "c"]
        )

        print("DragReorder checks passed")
    }
}
