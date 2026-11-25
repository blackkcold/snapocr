import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Notifies a microphone source when the AVAudioEngine input configuration
/// changes. The default engine implements this; fakes may implement it for
/// synthetic tests.
public protocol MicrophoneConfigurationChangeMonitoring: AnyObject, Sendable {
  /// Installs the configuration-change callback, or clears it with `nil`.
  ///
  /// - Parameter handler: Callback invoked on the platform notification queue.
  func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?)
}

/// A bounded broadcast of device-change events.
///
/// Each subscriber gets an independent stream. `finish()` terminates all
/// subscribers and makes late platform callbacks harmless; a source creates a
/// fresh broadcaster on the next start.
final class AudioDeviceChangeBroadcaster: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<AudioDeviceChangeEvent>.Continuation] = [:]
  private var finished = false

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func makeStream() -> AsyncStream<AudioDeviceChangeEvent> {
    AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
      let id = UUID()
      lock.lock()
      if finished {
        lock.unlock()
        continuation.finish()
        return
      }
      continuations[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.remove(id)
      }
    }
  }

  func yield(_ event: AudioDeviceChangeEvent) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    let current = Array(continuations.values)
    lock.unlock()
    for continuation in current {
      continuation.yield(event)
    }
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let current = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in current {
      continuation.finish()
    }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    continuations.removeValue(forKey: id)
    lock.unlock()
  }
}

/// A testable seam over AudioObject listener add/remove operations.
internal protocol AudioPropertyListenerRegistrar: AnyObject {
  func add(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus
  func remove(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  )
}

internal final class CoreAudioPropertyListenerRegistrar: AudioPropertyListenerRegistrar {
  func add(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
  }

  func remove(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: @escaping AudioObjectPropertyListenerBlock
  ) {
    AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
  }
}

// MARK: - CoreAudio device monitor

/// Registers CoreAudio default-device and same-device rate/layout listeners.
///
/// A default-device switch re-registers the device-object listeners for the new
/// input/output device. Native CoreAudio objects stay on the control side.
public final class CoreAudioDeviceChangeMonitor: AudioDeviceChangeMonitoring,
  @unchecked Sendable {
  /// The selectors this monitor registers for each current default device.
  public static let monitoredSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioDevicePropertyNominalSampleRate,
    kAudioDevicePropertyStreamConfiguration,
  ]

  private struct Registration {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }

  private let queue = DispatchQueue(label: "com.snapglass.device-monitor")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let lock = NSLock()
  private let registrar: any AudioPropertyListenerRegistrar
  private let defaultDeviceProvider: (RecordingTrackRole) -> AudioDeviceID?
  private let formatProvider: (AudioDeviceID, AudioObjectPropertyScope) -> AudioSourceFormat?
  private var handler: (@Sendable (AudioDeviceChangeEvent) -> Void)?
  private var defaultRegistrations: [Registration] = []
  private var deviceRegistrations: [Registration] = []
  private var running = false
  private var replacementFailed = false

  /// Whether the last same-device listener refresh failed while old listeners
  /// remained registered.
  public var lastReplacementFailed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return replacementFailed
  }

  /// Creates an unregistered monitor without reading device state.
  public convenience init() {
    self.init(
      registrar: CoreAudioPropertyListenerRegistrar(),
      defaultDeviceProvider: Self.defaultDevice,
      formatProvider: Self.deviceFormat
    )
  }

  internal init(
    registrar: any AudioPropertyListenerRegistrar,
    defaultDeviceProvider: @escaping (RecordingTrackRole) -> AudioDeviceID?,
    formatProvider: @escaping (AudioDeviceID, AudioObjectPropertyScope) -> AudioSourceFormat?
  ) {
    self.registrar = registrar
    self.defaultDeviceProvider = defaultDeviceProvider
    self.formatProvider = formatProvider
    queue.setSpecific(key: queueKey, value: 1)
  }

  /// Registers default-device and current-device listeners.
  ///
  /// - Parameter handler: Device change callback.
  /// - Throws: ``AudioSourceError/installFailed(_:)`` when a listener cannot register.
  public func start(_ handler: @escaping @Sendable (AudioDeviceChangeEvent) -> Void) throws {
    lock.lock()
    if running {
      self.handler = handler
      lock.unlock()
      return
    }
    self.handler = handler
    running = true
    replacementFailed = false
    lock.unlock()

    var defaults: [Registration] = []
    do {
      defaults = try addDefaultListeners()
      let devices = try addDeviceListeners()
      lock.lock()
      defaultRegistrations = defaults
      deviceRegistrations = devices
      lock.unlock()
    } catch {
      remove(defaults)
      stop()
      throw error
    }
  }

  /// Unregisters every listener and clears the callback.
  public func stop() {
    lock.lock()
    let defaults = defaultRegistrations
    let devices = deviceRegistrations
    defaultRegistrations = []
    deviceRegistrations = []
    running = false
    replacementFailed = false
    handler = nil
    lock.unlock()
    remove(defaults)
    remove(devices)
    if DispatchQueue.getSpecific(key: queueKey) == nil {
      queue.sync {}
    }
  }

  private func addDefaultListeners() throws -> [Registration] {
    var registrations: [Registration] = []
    do {
      registrations.append(
        try addListener(
          selector: kAudioHardwarePropertyDefaultInputDevice,
          role: .microphone
        )
      )
      registrations.append(
        try addListener(
          selector: kAudioHardwarePropertyDefaultOutputDevice,
          role: .system
        )
      )
      return registrations
    } catch {
      remove(registrations)
      throw error
    }
  }

  private func addDeviceListeners() throws -> [Registration] {
    var registrations: [Registration] = []
    do {
      for role in [RecordingTrackRole.microphone, .system] {
        guard let device = defaultDeviceProvider(role) else { continue }
        let scope: AudioObjectPropertyScope = role == .microphone
          ? kAudioObjectPropertyScopeInput
          : kAudioObjectPropertyScopeOutput
        registrations.append(
          try addDeviceListener(
            device: device,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            role: role
          )
        )
        registrations.append(
          try addDeviceListener(
            device: device,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: scope,
            role: role
          )
        )
      }
      return registrations
    } catch {
      remove(registrations)
      throw error
    }
  }

  private func addListener(
    selector: AudioObjectPropertySelector,
    role: RecordingTrackRole
  ) throws -> Registration {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.defaultDeviceDidChange(role: role)
    }
    let status = registrar.add(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      address: &address,
      queue: queue,
      block: block
    )
    guard status == noErr else {
      throw AudioSourceError.installFailed("CoreAudio default listener status \(status)")
    }
    return Registration(objectID: AudioObjectID(kAudioObjectSystemObject), address: address, block: block)
  }

  private func addDeviceListener(
    device: AudioDeviceID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    role: RecordingTrackRole
  ) throws -> Registration {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.emit(role: role)
    }
    let status = registrar.add(
      objectID: device,
      address: &address,
      queue: queue,
      block: block
    )
    guard status == noErr else {
      throw AudioSourceError.installFailed("CoreAudio device listener status \(status)")
    }
    return Registration(objectID: device, address: address, block: block)
  }

  private func defaultDeviceDidChange(role: RecordingTrackRole) {
    emit(role: role)
    refreshDeviceListeners()
  }

  internal func refreshDeviceListenersForTesting() {
    refreshDeviceListeners()
  }

  private func refreshDeviceListeners() {
    lock.lock()
    let old = deviceRegistrations
    let isRunning = running
    lock.unlock()
    guard isRunning else { return }
    guard let fresh = try? addDeviceListeners() else {
      // The old registrations remain live; replacement was transactional.
      lock.lock()
      replacementFailed = true
      lock.unlock()
      return
    }
    lock.lock()
    let stillRunning = running
    if stillRunning {
      deviceRegistrations = fresh
      replacementFailed = false
    }
    lock.unlock()
    if stillRunning {
      remove(old)
    } else {
      remove(fresh)
    }
  }

  private func remove(_ registrations: [Registration]) {
    for registration in registrations {
      var address = registration.address
      registrar.remove(
        objectID: registration.objectID,
        address: &address,
        queue: queue,
        block: registration.block
      )
    }
  }

  private func emit(role: RecordingTrackRole) {
    lock.lock()
    let callback = handler
    lock.unlock()
    guard let callback else { return }
    guard let device = defaultDeviceProvider(role) else { return }
    let scope: AudioObjectPropertyScope = role == .microphone
      ? kAudioObjectPropertyScopeInput
      : kAudioObjectPropertyScopeOutput
    guard let format = formatProvider(device, scope) else { return }
    let direction = role == .microphone ? "input" : "output"
    callback(
      AudioDeviceChangeEvent(
        role: role,
        deviceID: "coreaudio:\(direction):\(device)",
        format: format
      )
    )
  }

  private static func defaultDevice(for role: RecordingTrackRole) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: role == .microphone
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    )
    guard status == noErr, device != 0 else { return nil }
    return device
  }

  private static func deviceFormat(
    device: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> AudioSourceFormat? {
    var rateAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var rateSize = UInt32(MemoryLayout<Float64>.size)
    guard
      AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &sampleRate) == noErr,
      sampleRate > 0,
      sampleRate <= 768_000
    else {
      return nil
    }

    var layoutAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var layoutSize = UInt32(0)
    guard AudioObjectGetPropertyDataSize(device, &layoutAddress, 0, nil, &layoutSize) == noErr,
      layoutSize >= UInt32(MemoryLayout<AudioBufferList>.size)
    else {
      return nil
    }
    let byteCount = max(Int(layoutSize), MemoryLayout<AudioBufferList>.size)
    let rawList = UnsafeMutableRawPointer.allocate(
      byteCount: byteCount,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawList.deallocate() }
    let list = UnsafeMutableAudioBufferListPointer(
      rawList.assumingMemoryBound(to: AudioBufferList.self)
    )
    guard
      AudioObjectGetPropertyData(device, &layoutAddress, 0, nil, &layoutSize, rawList)
        == noErr
    else {
      return nil
    }
    let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
    guard channels == 1 || channels == 2 else { return nil }
    return AudioSourceFormat(sampleRate: Int(sampleRate.rounded()), channelCount: channels)
  }
}

/// An AVAudioEngine-backed microphone engine with one tap.
///
/// The engine is a native serial object used only from the source's control
/// gate; the tap callback is delivered on the engine's audio thread. The lock
/// protects install/running/handler bookkeeping, never the audio callback.
public final class AVAudioEngineMicrophoneCaptureEngine: NSObject, MicrophoneCaptureEngine,
  MicrophoneConfigurationChangeMonitoring, @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var installedTapFormat: AVAudioFormat?
  private var running = false
  private var configurationHandler: (@Sendable () -> Void)?
  private var configurationObserver: (any NSObjectProtocol)?

  /// Creates an engine without starting audio hardware.
  public override init() {
    super.init()
  }

  /// The input node's actual current format, not a cached tap request.
  public var currentFormat: AVAudioFormat? {
    Self.validatedInputFormat(engine.inputNode.inputFormat(forBus: 0))
  }

  /// Whether the engine's audio unit is running.
  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  /// Installs the single microphone tap after checking the actual input layout.
  ///
  /// - Parameters:
  ///   - format: Format that must match the input node's current format.
  ///   - handler: Audio callback.
  /// - Throws: ``AudioSourceError/invalidFormat`` when the requested format does
  ///   not match the input node, preventing an Objective-C tap assertion.
  public func installTap(
    format: AVAudioFormat,
    handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) throws {
    guard let actual = Self.validatedInputFormat(engine.inputNode.inputFormat(forBus: 0)),
      actual.sampleRate == format.sampleRate,
      actual.channelCount == format.channelCount,
      format.commonFormat == .pcmFormatFloat32
    else {
      throw AudioSourceError.invalidFormat
    }
    lock.lock()
    let alreadyInstalled = installedTapFormat != nil
    installedTapFormat = nil
    lock.unlock()
    if alreadyInstalled {
      engine.inputNode.removeTap(onBus: 0)
    }
    engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format, block: handler)
    lock.lock()
    installedTapFormat = format
    lock.unlock()
  }

  /// Removes the installed tap, if any.
  public func removeTap() {
    lock.lock()
    let installed = installedTapFormat != nil
    installedTapFormat = nil
    lock.unlock()
    guard installed else { return }
    engine.inputNode.removeTap(onBus: 0)
  }

  /// Starts the engine and observes configuration changes.
  ///
  /// - Throws: ``AudioSourceError/startFailed(_:)`` when the engine cannot start.
  public func start() throws {
    lock.lock()
    let alreadyRunning = running
    lock.unlock()
    guard !alreadyRunning else { return }
    addConfigurationObserver()
    do {
      try engine.start()
    } catch {
      removeConfigurationObserver()
      throw AudioSourceError.startFailed("AVAudioEngine start: \(error)")
    }
    lock.lock()
    running = true
    lock.unlock()
  }

  /// Stops the engine and removes the configuration observer.
  public func stop() {
    lock.lock()
    let wasRunning = running
    running = false
    lock.unlock()
    removeConfigurationObserver()
    guard wasRunning else { return }
    engine.stop()
  }

  /// Installs the configuration-change callback, or clears it with `nil`.
  public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
    lock.lock()
    configurationHandler = handler
    lock.unlock()
  }

  private func addConfigurationObserver() {
    lock.lock()
    let existing = configurationObserver
    lock.unlock()
    guard existing == nil else { return }
    let token = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.configurationDidChange()
    }
    lock.lock()
    configurationObserver = token
    lock.unlock()
  }

  private func removeConfigurationObserver() {
    lock.lock()
    let token = configurationObserver
    configurationObserver = nil
    lock.unlock()
    if let token {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func configurationDidChange() {
    lock.lock()
    running = false
    let handler = configurationHandler
    lock.unlock()
    handler?()
  }

  private static func validatedInputFormat(_ format: AVAudioFormat) -> AVAudioFormat? {
    guard format.sampleRate > 0,
      format.channelCount == 1 || format.channelCount == 2,
      format.commonFormat == .pcmFormatFloat32
    else {
      return nil
    }
    return format
  }
}

/// The callback-side immutable system-audio binding.
///
/// One serial ScreenCaptureKit queue invokes `handle`, so the preallocated
/// buffer list and planar pointer scratch are never used concurrently.
