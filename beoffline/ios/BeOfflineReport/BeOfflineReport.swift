import DeviceActivity
import SwiftUI
import ManagedSettings
import FamilyControls

@main
struct BeOfflineReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        SummaryScene(context: .today) { TodayView(summary: $0) }
        SummaryScene(context: .topApps) { AppsView(summary: $0, maxRows: 8, showTotal: false) }
        SummaryScene(context: .allTime) { AppsView(summary: $0, maxRows: 20, showTotal: true) }
        SummaryScene(context: .week) { WeekView(summary: $0) }
        SummaryScene(context: .limit) { LimitUsageView(summary: $0) }
    }
}

// ---------- dane ----------
struct AppRow: Identifiable {
    let id: String
    let name: String
    let token: ApplicationToken?
    var seconds: TimeInterval
}

struct DayRow: Identifiable {
    var id: Date { date }
    let date: Date
    var seconds: TimeInterval
}

struct Summary {
    var total: TimeInterval = 0
    var apps: [AppRow] = []
    var days: [DayRow] = []

    static func build(from data: DeviceActivityResults<DeviceActivityData>) async -> Summary {
        var total: TimeInterval = 0
        var apps: [String: AppRow] = [:]
        var days: [Date: TimeInterval] = [:]
        for await d in data {
            for await seg in d.activitySegments {
                total += seg.totalActivityDuration
                days[seg.dateInterval.start, default: 0] += seg.totalActivityDuration
                for await cat in seg.categories {
                    for await app in cat.applications {
                        let a = app.application
                        let key = a.bundleIdentifier ?? a.localizedDisplayName ?? UUID().uuidString
                        var row = apps[key] ?? AppRow(id: key,
                                                      name: a.localizedDisplayName ?? "Aplikacja",
                                                      token: a.token, seconds: 0)
                        row.seconds += app.totalActivityDuration
                        apps[key] = row
                    }
                }
            }
        }
        return Summary(
            total: total,
            apps: apps.values.sorted { $0.seconds > $1.seconds },
            days: days.map { DayRow(date: $0.key, seconds: $0.value) }.sorted { $0.date < $1.date })
    }
}

struct SummaryScene<V: View>: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let content: (Summary) -> V

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> Summary {
        await Summary.build(from: data)
    }
}

// ---------- widoki ----------
struct TodayView: View {
    let summary: Summary
    var body: some View {
        let limit = TimeInterval(SharedStore.deviceLimitMinutes * 60)
        VStack(spacing: 10) {
            Text(formatDurationPL(summary.total)).font(.largeTitle.bold())
            Text("Dzienny limit: \(formatDurationPL(limit))")
            ProgressView(value: min(summary.total / max(limit, 1), 1))
                .tint(.primary).scaleEffect(x: 1, y: 2.5)
                .padding(.vertical, 6)
            Text(summary.total >= limit
                 ? "Osiągnięto ustawiony limit."
                 : "Do limitu pozostało \(formatDurationPL(limit - summary.total)).")
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct AppsView: View {
    let summary: Summary
    let maxRows: Int
    let showTotal: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if showTotal {
                    Text("Od instalacji: \(formatDurationPL(summary.total))").font(.headline)
                }
                if summary.apps.isEmpty { Text("Brak danych.") }
                ForEach(summary.apps.prefix(maxRows)) { app in
                    HStack(spacing: 12) {
                        if let token = app.token {
                            Label(token).labelStyle(.iconOnly).font(.title)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.2)).frame(width: 40, height: 40)
                                .overlay(Text(String(app.name.prefix(1)).uppercased()))
                        }
                        Text(app.name).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        Text(formatDurationPL(app.seconds)).bold()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.2)))
                }
            }
            .padding(2)
        }
    }
}

struct WeekView: View {
    let summary: Summary
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f }()
    var body: some View {
        let maxV = max(summary.days.map(\.seconds).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(summary.days) { day in
                VStack(spacing: 4) {
                    Text(day.seconds == 0 ? "" : "\(Int(day.seconds) / 60)m").font(.system(size: 10))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary)
                        .frame(height: max(6, 110 * day.seconds / maxV))
                    Text(fmt.string(from: day.date)).font(.system(size: 10))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct LimitUsageView: View {
    let summary: Summary
    var body: some View {
        let tokens = Set(summary.apps.compactMap(\.token))
        let cfg = SharedStore.limits.first { !$0.selection.applicationTokens.isDisjoint(with: tokens) }
        let used = summary.total
        VStack(alignment: .leading, spacing: 6) {
            if let cfg {
                let limit = TimeInterval(cfg.dailyMinutes * 60)
                ProgressView(value: min(used / max(limit, 1), 1)).tint(.primary)
                HStack {
                    VStack(alignment: .leading) {
                        Text("Czas dzisiaj:").font(.caption2).foregroundColor(.secondary)
                        Text("\(formatDurationPL(used)) / \(cfg.dailyMinutes)m").font(.footnote.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Pozostało czasu:").font(.caption2).foregroundColor(.secondary)
                        Text(formatDurationPL(max(0, limit - used)))
                            .font(.footnote.bold())
                            .foregroundColor(used >= limit ? .red : .primary)
                    }
                }
            } else {
                Text("Czas dzisiaj: \(formatDurationPL(used))").font(.footnote.bold())
            }
        }
    }
}