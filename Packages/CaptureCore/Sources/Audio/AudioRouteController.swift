import Foundation

/// A prepared route change and its one-shot commit token.
public struct AudioRoutePreparation: Sendable {
  /// Token that must accompany ``AudioRouteController/commit(_:preparationID:)``.
  public let preparationID: UUID
  /// Whether preparation succeeded.
  public let result: RoutePreparationResult
  /// The single new generation when exactly one role changed.
  public let generation: AudioSourceGeneration?
  /// Mode that committing this preparation will actually activate.
  public let effectiveMode: AudioSourceMode
  /// Roles that committing this preparation will actually activate.
  public let effectiveRoles: Set<RecordingTrackRole>
  /// Why the effective route is narrower than the requested route, if it is.
  public let degradationReason: String?

  /// Creates a route preparation.
  ///
  /// - Parameters:
  ///   - preparationID: One-shot commit token.
  ///   - result: Preparation result.
  ///   - generation: New generation when exactly one changed.
  ///   - effectiveMode: Mode the commit will activate.
  ///   - effectiveRoles: Roles the commit will activate.
  ///   - degradationReason: Optional explanation for a narrower effective route.
  public init(
    preparationID: UUID,
    result: RoutePreparationResult,
    generation: AudioSourceGeneration?,
    effectiveMode: AudioSourceMode = .none,
    effectiveRoles: Set<RecordingTrackRole> = [],
    degradationReason: String? = nil
  ) {
    self.preparationID = preparationID
    self.result = result
    self.generation = generation
    self.effectiveMode = effectiveMode
    self.effectiveRoles = effectiveRoles
    self.degradationReason = degradationReason
  }
}

/// Coordinates two-phase source routing without restarting the session epoch.
///
/// Every public operation runs under an explicit asynchronous gate, so commits
/// cannot interleave even though an actor would be reentrant across `await`.
/// The class is `@unchecked Sendable` because its mutable state is only touched
/// while that gate is held.
public final class AudioRouteController: @unchecked Sendable {
  private struct PendingRoute {
    let id: UUID
    let requestedMode: AudioSourceMode
    let effectiveMode: AudioSourceMode
    let generations: [RecordingTrackRole: AudioSourceGeneration]
    let startedRoles: Set<RecordingTrackRole>
    let changedRoles: Set<RecordingTrackRole>
    let cancellations: [Cancellation]
  }

  private struct Cancellation {
    let role: RecordingTrackRole
    let generationID: UUID
  }

  private struct DeferredRetirement {
    let role: RecordingTrackRole
    let generation: AudioSourceGeneration
    let source: any AudioFrameSource
  }

  private let gate = AudioControlGate()
  private let authorizer: any MicrophoneAuthorizing
  private let sources: [RecordingTrackRole: any AudioFrameSource]
  private var activeMode: AudioSourceMode = .none
  private var activeRoles: Set<RecordingTrackRole> = []
  private var activeGenerations: [RecordingTrackRole: AudioSourceGeneration] = [:]
  private var pending: PendingRoute?
  private var retired: [AudioSourceGeneration] = []
  private var deferredRetirements: [DeferredRetirement] = []
  private var shutdownRequested = false

  /// Creates a controller over independent role sources.
  ///
  /// - Parameters:
  ///   - authorizer: Microphone authorization used for a pre-check without prompting.
  ///   - sources: Source per role; missing roles fail preparation.
  public init(
    authorizer: any MicrophoneAuthorizing,
    sources: [RecordingTrackRole: any AudioFrameSource]
  ) {
    self.authorizer = authorizer
    self.sources = sources
  }

  /// Prepares a source-mode change and returns a one-shot token.
  ///
  /// System failure fails the preparation. A denied microphone is omitted when
  /// system audio was also requested; microphone-only mode fails.
  ///
  /// - Parameter mode: Requested source mode.
  /// - Returns: Preparation token and result.
  public func prepare(_ mode: AudioSourceMode) async -> AudioRoutePreparation {
    guard await gate.acquireCancellable() else {
      return cancelledPreparation()
    }
    let result = await prepareLocked(mode)
    await gate.release()
    return result
  }

  /// Prepares a device-format change for an active role.
  ///
  /// - Parameter event: Device change to prepare.
  /// - Returns: Preparation token and result.
  public func prepareDeviceChange(_ event: AudioDeviceChangeEvent) async -> AudioRoutePreparation {
    guard await gate.acquireCancellable() else {
      return cancelledPreparation()
    }
    let result = await prepareDeviceChangeLocked(event)
    await gate.release()
    return result
  }

  /// Commits a prepared route at an integer sample position.
  ///
  /// The token must match the current pending preparation. A failed or stale
  /// commit leaves every healthy source untouched.
  ///
  /// - Parameters:
  ///   - event: Route event carrying the sample position and mode.
  ///   - preparationID: Token returned by a prepare call.
  /// - Returns: Commit result.
  public func commit(_ event: RouteEvent, preparationID: UUID) async -> RouteCommitResult {
    guard await gate.acquireCancellable() else {
      return .unchanged(reason: "cancelled")
    }
    let result = await commitLocked(event, preparationID: preparationID)
    await gate.release()
    return result
  }

  /// Returns the active generation for a role.
  ///
  /// - Parameter role: Logical recording role.
  /// - Returns: The active generation, or `nil` when the role is inactive.
  public func currentGeneration(for role: RecordingTrackRole) async -> AudioSourceGeneration? {
    guard await gate.acquireCancellable() else { return nil }
    await pruneUnhealthyActiveLocked()
    let value = activeGenerations[role]
    await gate.release()
    return value
  }

  /// Returns the mode actually active after the latest commit.
  ///
  /// - Returns: The effective mode, which can be narrower than the requested mode.
  public func currentEffectiveMode() async -> AudioSourceMode {
    guard await gate.acquireCancellable() else { return .none }
    await pruneUnhealthyActiveLocked()
    let value = activeMode
    await gate.release()
    return value
  }

  /// Returns the roles actually active after the latest commit.
  ///
  /// - Returns: The effective role set used by Task 6 for pump/progress.
  public func currentEffectiveRoles() async -> Set<RecordingTrackRole> {
    guard await gate.acquireCancellable() else { return [] }
    await pruneUnhealthyActiveLocked()
    let value = activeRoles
    await gate.release()
    return value
  }

  /// Takes every joined retired generation exactly once for Task 6.
  ///
  /// Each returned producer is joined and its ring has received `requestClose()`
  /// and one `finishProducing()` attempt. Unread frames remain readable. If the
  /// finish retained staging because the slot table was full, Task 6 must drain
  /// slots and call `finishProducing()` again until `retainedStagingFrames == 0`
  /// before reading the terminal gap. Do not restart a returned ring. A
  /// generation whose callback join timed out is withheld until a later call
  /// observes the producer joined.
  ///
  /// - Returns: Retired generations in retirement order; the list is cleared.
  public func takeRetiredGenerations() async -> [AudioSourceGeneration] {
    guard await gate.acquireCancellable() else { return [] }
    await pruneUnhealthyActiveLocked()
    await reapDeferredRetirementsLocked()
    let value = retired
    retired = []
    await gate.release()
    return value
  }

  /// Invalidates and rolls back the current preparation token.
  ///
  /// This is the explicit Task 6 stop path; it does not stop active sources that
  /// are not owned by the pending preparation.
  ///
  /// - Returns: `true` when a pending preparation was invalidated.
  public func cancelPendingPreparation() async -> Bool {
    await gate.acquire()
    let hadPending = pending != nil
    await supersedePendingLocked()
    await gate.release()
    return hadPending
  }

  /// Shuts this controller down permanently.
  ///
  /// Invalidates pending work, stops every configured source (including pending
  /// and failed transitions), clears the route, and refuses later prepare/commit.
  /// T6 must create a fresh controller for a new session.
  ///
  /// Deferred producers whose callbacks have not joined remain withheld from
  /// `takeRetiredGenerations()` until they are joined. The method is idempotent.
  ///
  /// - Returns: `true` when no deferred producer remains unjoined.
  public func shutdown() async -> Bool {
    await gate.acquire()
    shutdownRequested = true
    await supersedePendingLocked()
    for source in sources.values {
      await source.stop()
    }
    for (role, generation) in activeGenerations {
      if let source = sources[role] {
        await retireIfJoinedLocked(generation, source: source)
      }
    }
    activeGenerations = [:]
    activeRoles = []
    activeMode = .none
    pending = nil
    await reapDeferredRetirementsLocked()
    let complete = await allSourcesJoinedLocked() && deferredRetirements.isEmpty
    await gate.release()
    return complete
  }
  /// Returns whether explicit shutdown has no unjoined deferred producer.
  ///
  /// - Returns: `true` when all deferred producers have joined.
  public func isShutdownComplete() async -> Bool {
    guard await gate.acquireCancellable() else { return false }
    await reapDeferredRetirementsLocked()
    let sourcesJoined = await allSourcesJoinedLocked()
    let complete = shutdownRequested
      && pending == nil
      && activeRoles.isEmpty
      && activeGenerations.isEmpty
      && deferredRetirements.isEmpty
      && sourcesJoined
    await gate.release()
    return complete
  }

  private func allSourcesJoinedLocked() async -> Bool {
    for source in sources.values {
      guard await source.isProducerJoined() else {
        return false
      }
    }
    return true
  }
}

extension AudioRouteController {
  private static let roleOrder: [RecordingTrackRole] = [.system, .microphone]

  private static func roles(for mode: AudioSourceMode) -> [RecordingTrackRole] {
    switch mode {
    case .none: []
    case .system: [.system]
    case .microphone: [.microphone]
    case .systemAndMicrophone: [.system, .microphone]
    }
  }

  private static func mode(for roles: Set<RecordingTrackRole>) -> AudioSourceMode {
    if roles.contains(.system), roles.contains(.microphone) {
      return .systemAndMicrophone
    }
    if roles.contains(.system) {
      return .system
    }
    if roles.contains(.microphone) {
      return .microphone
    }
    return .none
  }

  private func cancelledPreparation() -> AudioRoutePreparation {
    AudioRoutePreparation(
      preparationID: UUID(),
      result: .unchangedOnFailure(reason: "cancelled"),
      generation: nil
    )
  }

  private func cancelledPreparationLocked() -> AudioRoutePreparation {
    AudioRoutePreparation(
      preparationID: UUID(),
      result: .unchangedOnFailure(reason: "cancelled"),
      generation: nil,
      effectiveMode: activeMode,
      effectiveRoles: activeRoles
    )
  }

  private func failure(_ reason: String) -> AudioRoutePreparation {
    AudioRoutePreparation(
      preparationID: UUID(),
      result: .unchangedOnFailure(reason: reason),
      generation: nil,
      effectiveMode: activeMode,
      effectiveRoles: activeRoles
    )
  }

  private struct PreparationState {
    var generations: [RecordingTrackRole: AudioSourceGeneration] = [:]
    var effectiveRoles: Set<RecordingTrackRole> = []
    var startedRoles: Set<RecordingTrackRole> = []
    var changedRoles: Set<RecordingTrackRole> = []
    var degradation: String?
  }

  private func prepareRole(
    _ role: RecordingTrackRole,
    desired: [RecordingTrackRole],
    state: inout PreparationState
  ) async -> String? {
    guard let source = sources[role] else {
      return "missing source for \(role)"
    }
    if activeRoles.contains(role), let active = activeGenerations[role],
      await source.isRunning() {
      state.generations[role] = active
      state.effectiveRoles.insert(role)
      return nil
    }
    if let stale = activeGenerations.removeValue(forKey: role) {
      activeRoles.remove(role)
      activeMode = Self.mode(for: activeRoles)
      await source.stop()
      await retireIfJoinedLocked(stale, source: source)
    }
    if role == .microphone, authorizer.currentState() != .authorized {
      if desired == [.microphone] {
        return "microphone authorization is unavailable"
      }
      state.degradation = "microphone authorization is unavailable"
      return nil
    }
    do {
      try await source.start()
    } catch {
      if Task.isCancelled {
        return "cancelled"
      }
      if role == .microphone, desired.contains(.system),
        let audioError = error as? AudioSourceError,
        case .microphoneNotAuthorized = audioError {
        state.degradation = "microphone authorization is unavailable"
        return nil
      }
      return "source start failed: \(error)"
    }
    state.startedRoles.insert(role)
    if Task.isCancelled {
      return "cancelled"
    }
    let retrieved = await source.currentGeneration()
    if Task.isCancelled {
      return "cancelled"
    }
    state.generations[role] = retrieved
    state.changedRoles.insert(role)
    state.effectiveRoles.insert(role)
    return nil
  }

  private func prepareLocked(_ mode: AudioSourceMode) async -> AudioRoutePreparation {
    if shutdownRequested {
      return failure("controller is shut down")
    }
    if Task.isCancelled {
      return cancelledPreparation()
    }
    await reapDeferredRetirementsLocked()
    let desired = Self.roles(for: mode)
    for role in desired where sources[role] == nil {
      return failure("missing source for \(role)")
    }
    if mode == .microphone, authorizer.currentState() != .authorized {
      return failure("microphone authorization is unavailable")
    }

    await supersedePendingLocked()
    var state = PreparationState()
    var failureReason: String?
    for role in Self.roleOrder where desired.contains(role) {
      if let reason = await prepareRole(role, desired: desired, state: &state) {
        failureReason = reason
        break
      }
    }

    if let failureReason {
      await rollbackStartedLocked(state.startedRoles)
      return failure(failureReason)
    }
    if Task.isCancelled {
      await rollbackStartedLocked(state.startedRoles)
      return cancelledPreparationLocked()
    }

    let id = UUID()
    let effectiveMode = Self.mode(for: state.effectiveRoles)
    pending = PendingRoute(
      id: id,
      requestedMode: mode,
      effectiveMode: effectiveMode,
      generations: state.generations,
      startedRoles: state.startedRoles,
      changedRoles: state.changedRoles,
      cancellations: []
    )
    let primary = state.changedRoles.count == 1
      ? state.changedRoles.first.flatMap { state.generations[$0] }
      : nil
    return AudioRoutePreparation(
      preparationID: id,
      result: .prepared,
      generation: primary,
      effectiveMode: effectiveMode,
      effectiveRoles: state.effectiveRoles,
      degradationReason: state.degradation
    )
  }

  private func prepareDeviceChangeLocked(_ event: AudioDeviceChangeEvent) async -> AudioRoutePreparation {
    if shutdownRequested {
      return failure("controller is shut down")
    }
    if Task.isCancelled {
      return cancelledPreparation()
    }
    await reapDeferredRetirementsLocked()
    guard activeRoles.contains(event.role), let source = sources[event.role] else {
      return failure("role is not active")
    }
    guard event.format.isRingCompatible else {
      return failure("unsupported device format")
    }
    guard await source.isRunning() else {
      return failure("role is not running")
    }
    let preparation = await source.prepareReconfiguration(event)
    guard case .prepared(let generation) = preparation else {
      if case .unchangedOnFailure(let reason) = preparation {
        return failure(reason)
      }
      return failure("unknown preparation failure")
    }
    if Task.isCancelled {
      if let cancellable = source as? any AudioSourceReconfigurationCancelling {
        await cancellable.cancelReconfiguration(generation.id)
      }
      return cancelledPreparation()
    }
    await supersedePendingLocked()
    if Task.isCancelled {
      if let cancellable = source as? any AudioSourceReconfigurationCancelling {
        await cancellable.cancelReconfiguration(generation.id)
      }
      return cancelledPreparationLocked()
    }
    var generations = activeGenerations
    generations[event.role] = generation
    let id = UUID()
    pending = PendingRoute(
      id: id,
      requestedMode: activeMode,
      effectiveMode: activeMode,
      generations: generations,
      startedRoles: [],
      changedRoles: [event.role],
      cancellations: [Cancellation(role: event.role, generationID: generation.id)]
    )
    return AudioRoutePreparation(
      preparationID: id,
      result: .prepared,
      generation: generation,
      effectiveMode: activeMode,
      effectiveRoles: activeRoles
    )
  }

  private func commitLocked(
    _ event: RouteEvent,
    preparationID: UUID
  ) async -> RouteCommitResult {
    await reapDeferredRetirementsLocked()
    await pruneUnhealthyActiveLocked()
    guard !shutdownRequested else {
      return .unchanged(reason: "controller is shut down")
    }
    guard let pending, pending.id == preparationID else {
      return .unchanged(reason: "stale preparation token")
    }
    guard event.atSample >= 0 else {
      return .unchanged(reason: "sample position must be nonnegative")
    }
    guard event.mode == pending.effectiveMode else {
      return .unchanged(reason: "route mode does not match effective preparation")
    }
    if Task.isCancelled {
      return .unchanged(reason: "cancelled")
    }
    if let reason = await validatePendingRolesLocked(pending, includeChanged: true) {
        await rollbackPendingLocked(pending)
        return .unchanged(reason: reason)
    }

    for role in Self.roleOrder where pending.changedRoles.contains(role) {
      guard let generation = pending.generations[role], let source = sources[role] else {
        await rollbackPendingLocked(pending)
        return .unchanged(reason: "prepared generation is missing")
      }
      let committed = await source.commitReconfiguration(generation)
      guard committed else {
        let removed = await pruneUnhealthyActiveLocked()
        await rollbackPendingLocked(pending)
        if removed.contains(role) {
          return .unchanged(reason: "source commit failed; active \(role) is unhealthy")
        }
        return .unchanged(reason: "source rejected generation commit")
      }
    }

    if let reason = await validatePendingRolesLocked(pending, includeChanged: false) {
        await pruneUnhealthyActiveLocked()
        await rollbackPendingLocked(pending)
        return .unchanged(reason: reason)
    }
    let desiredRoles = Set(pending.generations.keys)
    await retireReplacedGenerationsLocked(desiredRoles: desiredRoles)
    if let reason = await validatePendingRolesLocked(pending, includeChanged: true) {
        await pruneUnhealthyActiveLocked()
        await rollbackPendingLocked(pending)
        return .unchanged(reason: reason)
    }
    activeGenerations = pending.generations
    activeRoles = desiredRoles
    activeMode = pending.effectiveMode
    self.pending = nil
    return .committed(atSample: event.atSample)
  }

  private func validatePendingRolesLocked(
    _ pending: PendingRoute,
    includeChanged: Bool
  ) async -> String? {
    for role in Self.roleOrder where pending.generations[role] != nil {
      if !includeChanged, pending.changedRoles.contains(role) {
        continue
      }
      guard let source = sources[role], await source.isRunning() else {
        return "active \(role) stopped during commit"
      }
    }
    return nil
  }

  private func retireReplacedGenerationsLocked(
    desiredRoles: Set<RecordingTrackRole>
  ) async {
    for role in Self.roleOrder where activeRoles.contains(role) && !desiredRoles.contains(role) {
      if let source = sources[role] {
        await source.stop()
        if let old = activeGenerations[role] {
          await retireIfJoinedLocked(old, source: source)
        }
      } else if let old = activeGenerations[role] {
        retire(old)
      }
    }
    for role in Self.roleOrder where desiredRoles.contains(role) {
      if let old = activeGenerations[role],
        let new = pending?.generations[role],
        old.id != new.id,
        let source = sources[role] {
        await retireIfJoinedLocked(old, source: source)
      }
    }
  }

  private func rollbackPendingLocked(_ pending: PendingRoute) async {
    self.pending = nil
    await rollbackStartedLocked(pending.startedRoles)
    for cancellation in pending.cancellations {
      if let cancellable = sources[cancellation.role] as? any AudioSourceReconfigurationCancelling {
        await cancellable.cancelReconfiguration(cancellation.generationID)
      }
    }
  }

  private func rollbackStartedLocked(_ roles: Set<RecordingTrackRole>) async {
    for role in Self.roleOrder where roles.contains(role) {
      await sources[role]?.stop()
    }
  }

  private func supersedePendingLocked() async {
    guard let pending else { return }
    self.pending = nil
    await rollbackStartedLocked(pending.startedRoles)
    for cancellation in pending.cancellations {
      if let cancellable = sources[cancellation.role] as? any AudioSourceReconfigurationCancelling {
        await cancellable.cancelReconfiguration(cancellation.generationID)
      }
    }
  }

  @discardableResult
  private func pruneUnhealthyActiveLocked() async -> Set<RecordingTrackRole> {
    var removed: Set<RecordingTrackRole> = []
    for role in Self.roleOrder where activeRoles.contains(role) {
      guard let source = sources[role], await source.isRunning() else {
        activeRoles.remove(role)
        let generation = activeGenerations.removeValue(forKey: role)
        if let source = sources[role] {
          await source.stop()
          if let generation {
            await retireIfJoinedLocked(generation, source: source)
          }
        } else if let generation {
          retire(generation)
        }
        removed.insert(role)
        continue
      }
    }
    if !removed.isEmpty {
      activeMode = Self.mode(for: activeRoles)
    }
    return removed
  }

  private func retireIfJoinedLocked(
    _ generation: AudioSourceGeneration,
    source: any AudioFrameSource
  ) async {
    if await source.isProducerJoined() {
      retire(generation)
    } else if !deferredRetirements.contains(where: { $0.generation.id == generation.id }) {
      deferredRetirements.append(
        DeferredRetirement(role: generation.role, generation: generation, source: source)
      )
    }
  }

  private func reapDeferredRetirementsLocked() async {
    var remaining: [DeferredRetirement] = []
    for deferred in deferredRetirements {
      if await deferred.source.isProducerJoined() {
        retire(deferred.generation)
      } else {
        remaining.append(deferred)
      }
    }
    deferredRetirements = remaining
  }

  private func retire(_ generation: AudioSourceGeneration) {
    guard !retired.contains(where: { $0.id == generation.id }) else { return }
    retired.append(generation)
  }
}
