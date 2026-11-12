import Flutter
import UIKit
import SwiftUI
import DeviceActivity
import FamilyControls
import ManagedSettings

class ReportViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        ReportPlatformView(args: args as? [String: Any] ?? [:])
    }
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

class ReportPlatformView: NSObject, FlutterPlatformView {
    private let host: UIHostingController<ReportHost>

    init(args: [String: Any]) {
        let ms = (args["firstRun"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        host = UIHostingController(rootView: ReportHost(
            kind: args["kind"] as? String ?? "today",
            limitId: args["limitId"] as? String,
            firstRun: Date(timeIntervalSince1970: ms / 1000)))
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = (args["dark"] as? Bool ?? false) ? .dark : .light
        super.init()
    }

    func view() -> UIView { host.view }
}

private let allDevices = DeviceActivityFilter.Devices([.iPhone, .iPad])

struct ReportHost: View {
    let kind: String
    let limitId: String?
    let firstRun: Date

    private var today: DateInterval { Calendar.current.dateInterval(of: .day, for: Date())! }

    private func filter(_ interval: DateInterval) -> DeviceActivityFilter {
        DeviceActivityFilter(segment: .daily(during: interval), users: .all, devices: allDevices)
    }

    var body: some View {
        switch kind {
        case "today":
            DeviceActivityReport(.today, filter: filter(today))
        case "todayApps":
            DeviceActivityReport(.topApps, filter: filter(today))
        case "week":
            DeviceActivityReport(.week, filter: filter(DateInterval(
                start: Calendar.current.date(byAdding: .day, value: -6, to: today.start)!,
                end: today.end)))
        case "allTime":
            DeviceActivityReport(.allTime, filter: filter(DateInterval(
                start: min(firstRun, today.start), end: Date())))
        case "limit":
            if let cfg = SharedStore.limits.first(where: { $0.id == limitId }) {
                LimitCard(cfg: cfg, today: today)
            } else {
                Text("Brak ograniczenia")
            }
        default:
            EmptyView()
        }
    }
}

struct LimitCard: View {
    let cfg: LimitConfig
    let today: DateInterval

    var body: some View {
        let st = SharedStore.state(cfg.id)
        let remaining = max(0, cfg.totalSessions - st.sessionsUsed)
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(cfg.selection.applicationTokens), id: \.self) { Label($0) }
                    ForEach(Array(cfg.selection.categoryTokens), id: \.self) { Label($0) }
                    ForEach(Array(cfg.selection.webDomainTokens), id: \.self) { Label($0) }
                }
                .font(.subheadline.weight(.semibold))
            }
            Text("Limit: \(cfg.dailyMinutes) min dziennie (\(cfg.sessionMinutes)m/sesja)")
                .font(.caption).foregroundColor(.secondary)
            DeviceActivityReport(.limit, filter: DeviceActivityFilter(
                segment: .daily(during: today), users: .all, devices: allDevices,
                applications: cfg.selection.applicationTokens,
                categories: cfg.selection.categoryTokens,
                webDomains: cfg.selection.webDomainTokens))
                .frame(height: 64)
            Text("Sesje: \(st.sessionsUsed) / \(cfg.totalSessions) (zostało: \(remaining))")
                .font(.footnote.bold())
        }
        .padding(.horizontal, 4)
    }
}