import Testing

@testable import WindowLifecycleStateTests

/// 错误出口的分派：加载失败才该「重试」，资源丢失只能「打开目录」，
/// 复制失败要「再次复制」，普通动作失败只提示。
struct HistoryFailureTests {
    @Test func loadFailureOffersRetry() {
        #expect(HistoryFailure.recovery(for: .load) == .retryLoad)
    }

    @Test func copyFailureOffersCopyAgain() {
        #expect(HistoryFailure.recovery(for: .copy) == .retryCopy)
    }

    @Test func missingStorageOffersReveal() {
        #expect(HistoryFailure.recovery(for: .storage) == .revealStorage)
    }

    @Test func genericActionOnlyDismisses() {
        #expect(HistoryFailure.recovery(for: .action) == .dismiss)
    }
}
