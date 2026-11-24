import Foundation

// MARK: Track roles

extension RecordingExportPlanner {
    static func resolveOutputRoles(
        selection: ExportTrackSelection,
        layout: AudioOutputLayout,
        descriptorsByID: [UUID: [PlannerAudioDescriptor]]
    ) -> [RecordingTrackRole] {
        switch selection {
        case .mixed:
            return [.mixed]
        case .sourceSeparated:
            var found = Set(descriptorsByID.values.flatMap { $0.map(\.role) })
            if found.isEmpty, layout == .mixed { found = [.mixed] }
            if found.isEmpty { found = [.system, .microphone] }
            return RecordingCheckpointWriter.roleOrder.filter { found.contains($0) }
        }
    }

    static func matchingDescriptors(
        _ descriptors: [PlannerAudioDescriptor],
        outputRole: RecordingTrackRole
    ) -> [PlannerAudioDescriptor] {
        if outputRole == .mixed {
            let alreadyMixed = descriptors.filter { $0.role == .mixed }
            if !alreadyMixed.isEmpty { return alreadyMixed }
            return descriptors.filter { $0.role == .system || $0.role == .microphone }
        }
        return descriptors.filter { $0.role == outputRole }
    }

    /// Roles a published or recovered file carries for its segment.
    static func roles(
        for url: URL,
        segment: PublishedSegment,
        layout: AudioOutputLayout
    ) -> [RecordingTrackRole] {
        let fileRoles = segment.files.compactMap { rawRole, relative -> RecordingTrackRole? in
            guard URL(fileURLWithPath: relative).lastPathComponent == url.lastPathComponent else { return nil }
            return recordingRole(rawRole)
        }
        if !fileRoles.isEmpty { return Array(Set(fileRoles)).sorted { roleOrder($0) < roleOrder($1) } }
        let mapped = segment.trackMap.keys.compactMap(recordingRole)
        if mapped.count == 1 { return mapped }
        if layout == .mixed { return [.mixed] }
        if segment.trackMap.count > 1 {
            return RecordingCheckpointWriter.roleOrder.filter { mapped.contains($0) }
        }
        return []
    }

    static func recordingRole(_ name: String) -> RecordingTrackRole? {
        switch name.lowercased() {
        case "mixed": .mixed
        case "system": .system
        case "microphone", "mic": .microphone
        default: nil
        }
    }

    static func roleOrder(_ role: RecordingTrackRole) -> Int {
        switch role {
        case .mixed: 0
        case .system: 1
        case .microphone: 2
        }
    }
}
