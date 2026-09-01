import Foundation

/// Executes an asynchronous operation with a caller-provided timeout error.
public func withThrowingTimeout<T: Sendable>(
    milliseconds: Int,
    timeoutError: @escaping @Sendable () -> any Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(milliseconds))
            throw timeoutError()
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw timeoutError()
        }
        group.cancelAll()
        return result
    }
}

extension CGPoint {
    /// Clamps both coordinates to the supplied rectangle.
    public func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(x, rect.minX), rect.maxX),
            y: min(max(y, rect.minY), rect.maxY)
        )
    }
}

extension CGRect {
    /// Creates the axis-aligned rectangle spanning two points.
    public init(spanning first: CGPoint, and second: CGPoint) {
        self.init(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}
