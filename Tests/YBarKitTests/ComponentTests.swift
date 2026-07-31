import Foundation
import Testing
@testable import YBarKit

@MainActor
@Suite struct GraphStateTests {
    @Test func ringBufferOrdersOldestFirst() {
        let graph = GraphState(capacity: 3)
        graph.push(0.1)
        graph.push(0.2)
        graph.push(0.3)
        #expect(graph.ordered() == [0.1, 0.2, 0.3])
        graph.push(0.4)
        #expect(graph.ordered() == [0.2, 0.3, 0.4])
    }

    @Test func valuesClampToUnit() {
        let graph = GraphState(capacity: 2)
        graph.push(-1)
        graph.push(7)
        #expect(graph.ordered() == [0, 1])
    }

    @Test func derivedFillColorIsTranslucentLine() {
        let graph = GraphState(capacity: 2)
        graph.lineColor = YColor(argb: 0xFFFF_0000)
        #expect(abs(graph.effectiveFillColor.alpha - 0.2) < 0.001)
        graph.fillColor = YColor(argb: 0x8000_FF00)
        #expect(graph.effectiveFillColor.argb == 0x8000_FF00)
    }
}

@MainActor
@Suite struct SliderStateTests {
    @Test func percentageMapsLocalX() {
        let slider = SliderState(width: 200)
        #expect(slider.percentage(forLocalX: 0) == 0)
        #expect(slider.percentage(forLocalX: 100) == 50)
        #expect(slider.percentage(forLocalX: 200) == 100)
        #expect(slider.percentage(forLocalX: -50) == 0)
        #expect(slider.percentage(forLocalX: 500) == 100)
    }
}

@Suite struct ComponentGeometryTests {
    @Test func bracketUnionSpansMembersWithPadding() {
        let union = ComponentGeometry.bracketUnion(
            memberBoxes: [
                CGRect(x: 100, y: 0, width: 50, height: 30),
                CGRect(x: 180, y: 0, width: 40, height: 30),
            ],
            paddingLeft: 4, paddingRight: 6)
        #expect(union == CGRect(x: 96, y: 0, width: 130, height: 30))
    }

    @Test func bracketUnionSkipsHiddenMembers() {
        let union = ComponentGeometry.bracketUnion(
            memberBoxes: [.zero, CGRect(x: 10, y: 0, width: 20, height: 30)],
            paddingLeft: 0, paddingRight: 0)
        #expect(union == CGRect(x: 10, y: 0, width: 20, height: 30))
        #expect(ComponentGeometry.bracketUnion(memberBoxes: [.zero], paddingLeft: 0, paddingRight: 0) == nil)
    }

    @Test func popupLayoutStacksVertically() {
        let layout = ComponentGeometry.popupLayout(
            rows: [
                (itemID: 1, size: CGSize(width: 80, height: 20), paddingLeft: 2, paddingRight: 2),
                (itemID: 2, size: CGSize(width: 120, height: 24), paddingLeft: 0, paddingRight: 0),
            ],
            cellHeight: 0, horizontal: false, inset: 6)
        #expect(layout.boxes[1]?.minY == 6)
        #expect(layout.boxes[2]?.minY == 26)
        // Widest row (120) + insets defines panel width; height = rows + insets.
        #expect(layout.contentSize == CGSize(width: 132, height: 56))
    }

    @Test func popupLayoutRespectsFixedCellHeight() {
        let layout = ComponentGeometry.popupLayout(
            rows: [(itemID: 1, size: CGSize(width: 50, height: 12), paddingLeft: 0, paddingRight: 0)],
            cellHeight: 30, horizontal: false, inset: 0)
        #expect(layout.boxes[1]?.height == 30)
        #expect(layout.contentSize.height == 30)
    }

    @Test func graphTessellationCoversSegments() {
        let (fill, line) = ComponentGeometry.tessellateGraph(
            samples: [0, 0.5, 1],
            box: CGRect(x: 0, y: 0, width: 20, height: 10),
            lineWidth: 2, rightToLeft: false)
        // 2 segments -> 6 fill verts + 6 line verts each.
        #expect(fill.count == 12)
        #expect(line.count == 12)
        // First sample (0) sits at the baseline, last (1) at the top.
        #expect(fill.first?.y == 10)
        // Peak x of the final segment reaches the box's right edge.
        #expect(fill.contains { $0.x == 20 && $0.y == 0 })
    }

    @Test func graphTessellationDegenerateInputs() {
        let empty = ComponentGeometry.tessellateGraph(
            samples: [0.5], box: CGRect(x: 0, y: 0, width: 10, height: 10),
            lineWidth: 1, rightToLeft: false)
        #expect(empty.fill.isEmpty && empty.line.isEmpty)
    }
}

@MainActor
@Suite struct ComponentLayoutTests {
    @Test func sandwichWidthEntersLayout() {
        let item = Item(name: "g", position: .left)
        item.kind = .graph
        item.graph = GraphState(capacity: 60)
        item.label.string = "cpu"
        let measured = MeasuredContent(iconSize: .zero, labelSize: CGSize(width: 30, height: 12))
        #expect(Layout.naturalLength(item: item, measured: measured) == 90)
    }

    @Test func bracketsAndPopupItemsAreOutOfFlow() {
        let bracket = Item(name: "b", position: .left)
        bracket.kind = .bracket
        let popupItem = Item(name: "p", position: .popup)
        popupItem.popupHost = "host"
        let normal = Item(name: "n", position: .left)
        normal.label.string = "x"

        Layout.perform(
            items: [bracket, popupItem, normal],
            barSize: CGSize(width: 500, height: 30),
            settings: BarSettings()
        ) { _ in MeasuredContent(iconSize: .zero, labelSize: CGSize(width: 40, height: 12)) }

        #expect(bracket.frame == .zero)
        #expect(popupItem.frame == .zero)
        #expect(normal.frame.minX == 0)
        #expect(normal.frame.width == 40)
    }
}

@MainActor
@Suite struct BracketFrameTests {
    @Test func bracketFramesSpanMembersAtFullBarHeight() {
        let a = Item(name: "a", position: .left)
        let b = Item(name: "b", position: .left)
        let bracket = Item(name: "grp", position: .left)
        bracket.kind = .bracket
        bracket.members = ["a", "b"]

        let frames = ComponentGeometry.bracketFrames(
            items: [a, b, bracket],
            contentBoxes: [
                a.id: CGRect(x: 10, y: 0, width: 40, height: 30),
                b.id: CGRect(x: 60, y: 0, width: 30, height: 30),
            ],
            barHeight: 32)
        #expect(frames[bracket.id] == CGRect(x: 10, y: 0, width: 80, height: 32))
    }

    @Test func bracketWithoutVisibleMembersGetsZeroFrame() {
        let bracket = Item(name: "grp", position: .left)
        bracket.kind = .bracket
        bracket.members = ["ghost"]
        let frames = ComponentGeometry.bracketFrames(
            items: [bracket], contentBoxes: [:], barHeight: 32)
        #expect(frames[bracket.id] == .zero)
    }
}
