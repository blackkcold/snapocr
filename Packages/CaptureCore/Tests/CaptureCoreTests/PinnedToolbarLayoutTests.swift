import CoreGraphics
import Testing

@testable import CaptureCore

struct PinnedToolbarLayoutTests {
    // MARK: - 档位选择

    @Test func regularChosenWhenWidthSufficient() {
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: 400) == .regular)
    }

    @Test func compactChosenWhenWidthTight() {
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: 260) == .compact)
    }

    @Test func boundaryAtRegularMinimumStaysRegular() {
        let minimum = PinnedToolbarLayout.regular.minimumWidth
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: minimum) == .regular)
        // 差 1 点即降档，避免边界抖动。
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: minimum - 1) == .compact)
    }

    @Test func invalidAvailableWidthFallsBackToCompact() {
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: 0) == .compact)
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: -20) == .compact)
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: .nan) == .compact)
        #expect(PinnedImageGeometry.toolbarLayout(availableWidth: .infinity) == .compact)
    }

    // MARK: - 响应式伸缩

    @Test func slidersFlexToFillAvailableWidth() {
        let width = PinnedImageGeometry.toolbarWidth(layout: .regular, availableWidth: 400)
        #expect(width == 400)
        // 剩余宽度由两根滑杆平分，且不在区间边界上（即真的在伸缩）。
        let slider = PinnedImageGeometry.toolbarSliderWidth(layout: .regular, availableWidth: 400)
        #expect(slider > PinnedToolbarLayout.regular.sliderRange.lowerBound)
        #expect(slider < PinnedToolbarLayout.regular.sliderRange.upperBound)
    }

    @Test func widthCappedAtSliderMaximum() {
        // 屏幕再宽也不会无限变宽，滑杆封顶后总宽停在档位上限。
        #expect(
            PinnedImageGeometry.toolbarWidth(layout: .regular, availableWidth: 600)
                == PinnedToolbarLayout.regular.maximumWidth
        )
        #expect(
            PinnedImageGeometry.toolbarWidth(layout: .regular, availableWidth: 5000)
                == PinnedToolbarLayout.regular.maximumWidth
        )
    }

    @Test func compactSlidersFlexAndCap() {
        #expect(PinnedImageGeometry.toolbarWidth(layout: .compact, availableWidth: 250) == 250)
        #expect(
            PinnedImageGeometry.toolbarWidth(layout: .compact, availableWidth: 400)
                == PinnedToolbarLayout.compact.maximumWidth
        )
    }

    @Test func slidersBottomOutAtTierMinimum() {
        // 可用宽度不足时滑杆退到下限，绝不出现负宽度或越界。
        let regular = PinnedImageGeometry.toolbarWidth(layout: .regular, availableWidth: 0)
        #expect(regular == PinnedToolbarLayout.regular.minimumWidth)
        let compact = PinnedImageGeometry.toolbarWidth(layout: .compact, availableWidth: 10)
        #expect(compact == PinnedToolbarLayout.compact.minimumWidth)
    }

    @Test func sliderWidthNeverOutsideTierRange() {
        for available in stride(from: CGFloat(100), through: 1000, by: 25) {
            let layout = PinnedImageGeometry.toolbarLayout(availableWidth: available)
            let slider = PinnedImageGeometry.toolbarSliderWidth(layout: layout, availableWidth: available)
            #expect(layout.sliderRange.contains(slider))
            #expect(
                PinnedImageGeometry.toolbarWidth(layout: layout, availableWidth: available)
                    == layout.fixedWidth + 2 * slider
            )
        }
    }

    @Test func clampedWidthNeverExceedsAvailableWidth() {
        // 极端窄屏：compact 下限仍放不下时按可用宽度收窄，不让窗口溢出。
        #expect(PinnedImageGeometry.clampedToolbarWidth(layout: .compact, availableWidth: 150) == 150)
        #expect(
            PinnedImageGeometry.clampedToolbarWidth(layout: .regular, availableWidth: 400) == 400
        )
        #expect(
            PinnedImageGeometry.clampedToolbarWidth(layout: .regular, availableWidth: 5000)
                == PinnedToolbarLayout.regular.maximumWidth
        )
    }

    @Test func integralSizeRoundsUpSoContentNeverOverflows() {
        let rounded = PinnedImageGeometry.integralToolbarSize(CGSize(width: 400, height: 35.5))
        #expect(rounded == CGSize(width: 400, height: 36))
        // 半点滑杆宽度取整后只会变宽，不会让内容超出窗口。
        let slack = PinnedImageGeometry.integralToolbarSize(CGSize(width: 399.5, height: 36))
        #expect(slack.width == 400)
        #expect(PinnedImageGeometry.integralToolbarSize(.zero) == .zero)
    }

    // MARK: - 固定件与档位差异

    @Test func compactHidesLeadingIconsKeepsReadout() {
        #expect(PinnedToolbarLayout.compact.showsLeadingIcons == false)
        #expect(PinnedToolbarLayout.regular.showsLeadingIcons == true)
        // 读数宽度两档都保留（只是收窄），否则无法读出百分比。
        #expect(PinnedToolbarLayout.compact.percentLabelWidth > 0)
        #expect(
            PinnedToolbarLayout.compact.percentLabelWidth < PinnedToolbarLayout.regular.percentLabelWidth
        )
    }

    @Test func fixedWidthMatchesElementSum() {
        // regular：14 + 14 + 1 + 38 + 34 + 34 = 135，间隙 7×6 = 42，边距 2×10 = 20。
        #expect(PinnedToolbarLayout.regular.fixedWidth == 197)
        // compact：1 + 32 + 28 + 28 = 89，间隙 5×4 = 20，边距 2×8 = 16。
        #expect(PinnedToolbarLayout.compact.fixedWidth == 125)
    }

    @Test func minimumWidthMatchesFixedPlusSliders() {
        #expect(
            PinnedToolbarLayout.regular.minimumWidth
                == PinnedToolbarLayout.regular.fixedWidth + 2 * PinnedToolbarLayout.regular.sliderRange.lowerBound
        )
        #expect(
            PinnedToolbarLayout.compact.minimumWidth
                == PinnedToolbarLayout.compact.fixedWidth + 2 * PinnedToolbarLayout.compact.sliderRange.lowerBound
        )
        #expect(PinnedToolbarLayout.regular.minimumWidth == 301)
        #expect(PinnedToolbarLayout.compact.minimumWidth == 197)
        // compact 封顶宽度必须低于 regular 的选择门槛，否则「刚好选中 regular」时会比紧凑档还窄。
        #expect(PinnedToolbarLayout.compact.maximumWidth < PinnedToolbarLayout.regular.minimumWidth)
    }

    @Test func compactIsNarrowerAndShorterThanRegular() {
        #expect(PinnedToolbarLayout.compact.maximumWidth < PinnedToolbarLayout.regular.maximumWidth)
        #expect(PinnedToolbarLayout.compact.minimumHeight < PinnedToolbarLayout.regular.minimumHeight)
        #expect(PinnedToolbarLayout.compact.marginHorizontal >= 8)
        #expect(PinnedToolbarLayout.compact.marginVertical >= 6)
    }

    /// 回归护栏：高度下限必须容得下「内容高 + 上下边距」。
    ///
    /// 曾因窗口高度比内容矮（边距约束符号错误使 `fittingSize` 吃掉 2×marginVertical）
    /// 被 `masksToBounds` 裁切而显示不全。
    @Test func minimumHeightFitsContentPlusVerticalMargins() {
        for layout in PinnedToolbarLayout.allCases {
            #expect(layout.minimumHeight == layout.contentHeight + 2 * layout.marginVertical)
            // 上下边距必须真的计入高度，否则控件会被圆角裁切。
            #expect(layout.minimumHeight - layout.contentHeight == 2 * layout.marginVertical)
            #expect(layout.minimumHeight > layout.contentHeight)
        }
        #expect(PinnedToolbarLayout.regular.contentHeight == 20)
        #expect(PinnedToolbarLayout.compact.contentHeight == 18)
        #expect(PinnedToolbarLayout.regular.minimumHeight == 36)
        #expect(PinnedToolbarLayout.compact.minimumHeight == 30)
        // 与 0.8.1 已发布的工具条高度（40pt）相比更紧凑，但必须仍高于内容。
        #expect(PinnedToolbarLayout.regular.minimumHeight < 40)
    }
}
