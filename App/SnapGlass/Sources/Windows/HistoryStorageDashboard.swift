import SwiftUI
import HistoryCore

struct HistoryStorageDashboard: View {
    let storageSizeGB: Double

    @State private var stats: HistoryStats?
    @State private var isLoading = true

    private let history = HistoryActor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Storage Overview")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading history statistics…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if let stats {
                statsContent(stats)
            } else {
                Text("History statistics unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(14)
        .glassSurface(in: .rounded(14))
        .task { await refresh() }
    }

    @ViewBuilder
    private func statsContent(_ stats: HistoryStats) -> some View {
        let storageUsedGB = Double(stats.totalSizeBytes) / 1_073_741_824

        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: .infinity), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                metricCard(
                    icon: "square.stack.3d.up",
                    title: "Entries",
                    value: "\(stats.totalCount)",
                    tint: .blue
                )
                metricCard(
                    icon: "star.fill",
                    title: "Favourites",
                    value: "\(stats.favouriteCount)",
                    tint: .yellow
                )
                metricCard(
                    icon: "gauge.with.dots.needle.50percent",
                    title: "Avg. confidence",
                    value: stats.averageConfidence.formatted(.percent.precision(.fractionLength(0))),
                    tint: .green
                )
                metricCard(
                    icon: "internaldrive",
                    title: "Storage used",
                    value: "\(storageUsedGB.formatted(.number.precision(.fractionLength(2)))) GB",
                    tint: .purple
                )
            }

            Divider()

            HStack(alignment: .top, spacing: 20) {
                if !stats.captureModeDistribution.isEmpty {
                    modeBars(stats.captureModeDistribution)
                } else {
                    Text("No captures yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }

                usageRing(storageUsedGB: storageUsedGB, capGB: storageSizeGB)
            }
        }
    }

    private func metricCard(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func modeBars(_ distribution: [String: Int]) -> some View {
        let total = max(distribution.values.reduce(0, +), 1)
        let data = distribution
            .sorted { $0.value > $1.value }
            .map { (mode: $0.key, count: $0.value) }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Capture modes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(data, id: \.mode) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.mode.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(total)))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func usageRing(storageUsedGB: Double, capGB: Double) -> some View {
        let ratio = capGB > 0 ? min(max(storageUsedGB / capGB, 0), 1) : 0

        return VStack(spacing: 8) {
            Gauge(value: ratio) {
                EmptyView()
            } currentValueLabel: {
                Text(ratio.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(ratio > 0.85 ? .red : (ratio > 0.6 ? .orange : .green))
            .frame(width: 90, height: 90)

            Text("of \(capGB.formatted(.number.precision(.fractionLength(1)))) GB limit")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func refresh() async {
        guard let history else {
            stats = nil
            isLoading = false
            return
        }
        do {
            stats = try await history.stats()
        } catch {
            stats = nil
        }
        isLoading = false
    }
}

