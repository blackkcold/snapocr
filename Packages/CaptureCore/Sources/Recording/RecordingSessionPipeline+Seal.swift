import Foundation

extension RecordingSessionPipeline {
    func consumeSealSignals(_ stream: AsyncStream<SealSignal>) async {
        for await signal in stream {
            switch signal {
            case .closed(let index):
                if !sealQueue.contains(index) { sealQueue.append(index) }
                await processSealQueue(retryDeferred: false)
            case .retry:
                await processSealQueue(retryDeferred: true)
            }
        }
        await processSealQueue(retryDeferred: false)
        if !deferredSealIndices.isEmpty {
            pipelineFailure = pipelineFailure ?? "seal deferred by space gate"
        }
    }

    func signalSealRetry() { sealContinuation?.yield(.retry) }

    func processSealQueue(retryDeferred: Bool) async {
        guard !processingSeal else { return }
        processingSeal = true
        defer { processingSeal = false }
        while let index = sealQueue.first {
            if deferredSealIndices.contains(index), !retryDeferred { return }
            sealQueue.removeFirst()
            deferredSealIndices.remove(index)
            let backlog = await checkpointSink?.sealBacklogBytes() ?? 0
            if let spaceGate {
                switch await spaceGate.admitSeal(segmentIndex: index, backlogBytes: backlog) {
                case .run: break
                case .defer:
                    deferredSealIndices.insert(index)
                    sealQueue.insert(index, at: 0)
                    return
                case .stop(let reason):
                    requestSpaceSafeStop(reason: "space gate stopped sealing: \(reason)")
                    return
                }
            }
            await seal(index)
        }
    }

    func seal(_ index: Int) async {
        let started = ContinuousClock.now
        do {
            let bundle = try await coordinator.closeSegmentBundle(at: index, isFinal: true)
            let segmentID = await ledger.segmentID(for: index)
            let sessionRecord = try await ledger.snapshot()
            diagnosticBroadcaster.yield(
                .init(
                    phase: .sealStarted,
                    sessionID: ledger.sessionID,
                    segmentIndex: index,
                    range: RecordingSampleRange(
                        startSample: bundle.coverage.segmentStartSample,
                        sampleCount: bundle.coverage.segmentEndSample - bundle.coverage.segmentStartSample
                    ),
                    byteCount: Self.byteCount(bundle.checkpoints.checkpoints)
                ))
            let context = RecordingSealContext(
                sessionID: ledger.sessionID,
                kind: .audio,
                layout: sessionRecord.layout,
                sampleRate: 48_000,
                outputStem: "Recording-\(ledger.sessionID.uuidString.lowercased())",
                destinationDirectory: roots.outputDirectory,
                bitRate: activeConfiguration?.bitRate
            )
            let sealed = try await sealService.seal(
                bundle, videoChunks: [], segmentID: segmentID, context: context
            )
            let intent = try await ledger.publishIntent(segmentID: segmentID)
            try await ledger.markPublished(try makePublishedRecord(sealed, intent: intent, coverage: bundle.coverage))
            await checkpointSink?.sealFinished(segmentIndex: index)
            let duration = started.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            diagnosticBroadcaster.yield(
                .init(
                    phase: .sealFinished,
                    sessionID: ledger.sessionID,
                    segmentIndex: index,
                    range: RecordingSampleRange(
                        startSample: sealed.effectiveRange.startSample,
                        sampleCount: sealed.effectiveRange.sampleCount
                    ),
                    durationSeconds: seconds
                ))
            diagnosticBroadcaster.yield(
                .init(
                    phase: .published,
                    sessionID: ledger.sessionID,
                    segmentIndex: index,
                    range: RecordingSampleRange(
                        startSample: sealed.effectiveRange.startSample,
                        sampleCount: sealed.effectiveRange.sampleCount
                    )
                ))
            await publishProgress()
        } catch {
            pipelineFailure = pipelineFailure ?? "segment seal/publish failed: \(error)"
        }
    }

    func makePublishedRecord(
        _ sealed: SealedSegment,
        intent: RecordingPublishIntent,
        coverage: RecordingSegmentCoverage
    ) throws -> PublishedSegment {
        guard sealed.segmentID == intent.segmentID, sealed.index == intent.segmentIndex,
            sealed.effectiveRange.startSample == intent.effectiveRange.startSample,
            sealed.effectiveRange.sampleCount == intent.effectiveRange.sampleCount
        else { throw RecordingSessionLedgerError.invalidPublication }
        var files: [String: String] = [:]
        var trackMap: [String: Int] = [:]
        for (role, url) in sealed.files {
            let name = Self.roleName(role)
            files[name] = try RecordingLedgerFileSystem.validateChild(url, under: roots.outputDirectory)
            guard let trackIndex = sealed.trackMap[role] else { throw RecordingSessionLedgerError.invalidPublication }
            trackMap[name] = trackIndex
        }
        return PublishedSegment(
            id: sealed.segmentID,
            index: sealed.index,
            files: files,
            startSample: sealed.effectiveRange.startSample,
            sampleCount: sealed.effectiveRange.sampleCount,
            trackMap: trackMap,
            missingRanges: coverage.tracks.filter(\.wasActive).flatMap(\.missingRanges),
            state: .published,
            videoURL: sealed.videoURL,
            videoTrackIndex: sealed.videoTrackIndex
        )
    }

    static func roleName(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    static func byteCount(_ commits: [CheckpointCommit]) -> Int64 {
        commits.reduce(into: Int64(0)) { total, commit in
            for url in commit.trackURLs.values {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                    total += size.int64Value
                }
            }
        }
    }
}
