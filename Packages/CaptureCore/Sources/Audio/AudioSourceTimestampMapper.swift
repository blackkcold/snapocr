import CoreMedia
import Foundation

/// Maps source presentation timestamps into one explicit host-clock domain.
///
/// The mapper never guesses that a media-timescale PTS is already an absolute
/// mach timestamp. Callers provide the anchor pair once, then every relative
/// PTS is converted with integer arithmetic into ticks of the configured host
/// domain. Invalid or overflowing values return `nil`; the native callback is
/// responsible for its bounded host-clock fallback.
public struct AudioSourceTimestampMapper: Sendable {
  /// Host-clock ticks per second used by the ring and the caller.
  public let hostTicksPerSecond: UInt64
  private let anchorPTS: CMTime
  private let anchorHostTime: UInt64

  /// Creates a mapper anchored at one presentation/host pair.
  ///
  /// - Parameters:
  ///   - hostTicksPerSecond: Host-clock ticks per second.
  ///   - anchorPTS: Presentation timestamp observed with `anchorHostTime`.
  ///   - anchorHostTime: Host tick that corresponds to `anchorPTS`.
  public init(hostTicksPerSecond: UInt64, anchorPTS: CMTime, anchorHostTime: UInt64) {
    self.hostTicksPerSecond = hostTicksPerSecond
    self.anchorPTS = anchorPTS
    self.anchorHostTime = anchorHostTime
  }

  /// Converts a presentation timestamp into the anchored host domain.
  ///
  /// - Parameter pts: Presentation timestamp to map.
  /// - Returns: Host ticks, or `nil` for an invalid, negative, or overflowing
  ///   timestamp.
  public func hostTime(for pts: CMTime) -> UInt64? {
    guard hostTicksPerSecond > 0, hostTicksPerSecond <= UInt64(Int64.max) else {
      return nil
    }
    guard pts.isValid, pts.timescale > 0, anchorPTS.isValid, anchorPTS.timescale > 0 else {
      return nil
    }
    let delta = CMTimeSubtract(pts, anchorPTS)
    guard delta.isValid, delta.timescale > 0, delta.value >= 0 else {
      return nil
    }
    let (scaled, multiplyOverflow) = delta.value.multipliedReportingOverflow(
      by: Int64(hostTicksPerSecond)
    )
    guard !multiplyOverflow else {
      return nil
    }
    let ticks = scaled / Int64(delta.timescale)
    guard ticks >= 0 else {
      return nil
    }
    let (hostTime, addOverflow) = anchorHostTime.addingReportingOverflow(UInt64(ticks))
    guard !addOverflow else {
      return nil
    }
    return hostTime
  }

  /// Converts native mach ticks into the configured host tick domain.
  ///
  /// - Parameters:
  ///   - machTicks: Tick count from `AudioGetCurrentHostTime()`.
  ///   - machTicksPerSecond: Native mach frequency.
  ///   - hostTicksPerSecond: Configured ring host frequency.
  /// - Returns: Converted ticks, or `0` for an invalid frequency.
  public static func hostTicks(
    fromMachTicks machTicks: UInt64,
    machTicksPerSecond: UInt64,
    hostTicksPerSecond: UInt64
  ) -> UInt64 {
    guard machTicksPerSecond > 0, hostTicksPerSecond > 0 else {
      return 0
    }
    if machTicksPerSecond == hostTicksPerSecond {
      return machTicks
    }
    let converted = Double(machTicks) * Double(hostTicksPerSecond) / Double(machTicksPerSecond)
    guard converted.isFinite, converted >= 0, converted < Double(UInt64.max) else {
      return 0
    }
    return UInt64(converted.rounded())
  }

  /// Returns the native host clock frequency as an integer tick rate.
  ///
  /// - Returns: The machine host frequency, or `1` if the platform reported an
  ///   unusable value.
  public static func nativeHostTicksPerSecond() -> UInt64 {
    let frequency = AudioGetHostClockFrequency()
    guard frequency.isFinite, frequency > 0, frequency < Double(UInt64.max) else {
      return 1
    }
    return UInt64(frequency.rounded())
  }
}
