import Flutter
import UIKit
import SwiftUI
import FamilyControls
import DeviceActivity
import ManagedSettings

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var pending: [String: FamilyActivitySelection] = [:]

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        GeneratedPluginRegistrant.register(with: self)

        let registrar = self.registrar(forPlugin: "BeOfflineScreenTime")!
        let messenger = registrar.messenger()
        registrar.register(ReportViewFactory(), withId: "beoffline/report")

        FlutterMethodChannel(name: "beoffline/ios_screentime", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                self?.handle(call, result)
            }

        // Ten sam kanał co na Androidzie – StreakPage działa bez zmian
        FlutterMethodChannel(name: "beoffline/sessions", binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                if call.method == "getStreak" {
                    result(SharedStore.streakJSON())
                } else {
                    result("{}")
                }
            }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "authStatus":
            result(AuthorizationCenter.shared.authorizationStatus == .approved)

        case "requestAuth":
            Task {
                var ok = false
                do {
                    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    ok = true
                } catch {
                    print("Auth error: \(error)")
                }
                DispatchQueue.main.async { result(ok) }
            }

        case "hasDeviceSelection":
            result(SharedStore.deviceSelection != nil)

        case "pickDeviceSelection":
            presentPicker(initial: SharedStore.deviceSelection ?? FamilyActivitySelection()) { sel in
                if let sel {
                    SharedStore.deviceSelection = sel
                    Scheduler.restart()
                }
                result(sel != nil)
            }

        case "setDeviceSettings":
            if let m = args["limitMinutes"] as? Int { SharedStore.deviceLimitMinutes = m }
            if let n = args["notifications"] as? Bool { SharedStore.notificationsEnabled = n }
            if AuthorizationCenter.shared.authorizationStatus == .approved { Scheduler.restart() }
            result(nil)

        case "pickLimitApps":
            let id = args["id"] as? String
            let existing = id.flatMap { i in SharedStore.limits.first { $0.id == i }?.selection }
            let initial = id.flatMap { pending[$0] } ?? existing ?? FamilyActivitySelection()
            presentPicker(initial: initial) { [weak self] sel in
                guard let sel else { result(nil); return }
                let newId = id ?? UUID().uuidString
                self?.pending[newId] = sel
                result(newId)
            }

        case "saveLimit":
            guard let id = args["id"] as? String,
                  let daily = args["daily"] as? Int,
                  let session = args["session"] as? Int,
                  let wait = args["wait"] as? Int else { result(false); return }
            var list = SharedStore.limits
            let old = list.first { $0.id == id }
            guard let selection = pending[id] ?? old?.selection else { result(false); return }
            let cfg = LimitConfig(id: id, selection: selection, dailyMinutes: daily,
                                  sessionMinutes: session, waitSeconds: wait)
            list.removeAll { $0.id == id }
            list.append(cfg)
            SharedStore.limits = list
            pending.removeValue(forKey: id)
            removeShield(id)
            Scheduler.restart()
            result(true)

        case "removeLimit":
            if let id = args["id"] as? String {
                SharedStore.limits = SharedStore.limits.filter { $0.id != id }
                removeShield(id)
                Scheduler.restart()
            }
            result(nil)

        case "getLimits":
            let arr: [[String: Any]] = SharedStore.limits.map { cfg in
                let st = SharedStore.state(cfg.id)
                return [
                    "id": cfg.id,
                    "daily": cfg.dailyMinutes,
                    "session": cfg.sessionMinutes,
                    "wait": cfg.waitSeconds,
                    "apps": cfg.selection.applicationTokens.count,
                    "categories": cfg.selection.categoryTokens.count,
                    "sessionsUsed": st.sessionsUsed,
                    "dailyReached": st.dailyReached,
                ]
            }
            result(arr)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func presentPicker(initial: FamilyActivitySelection,
                               completion: @escaping (FamilyActivitySelection?) -> Void) {
        let model = PickerModel(selection: initial)
        var host: UIViewController?
        let screen = PickerScreen(model: model) { sel in
            host?.dismiss(animated: true) { completion(sel) }
        }
        let vc = UIHostingController(rootView: screen)
        vc.isModalInPresentation = true
        host = vc
        window?.rootViewController?.present(vc, animated: true)
    }
}

final class PickerModel: ObservableObject {
    @Published var selection: FamilyActivitySelection
    init(selection: FamilyActivitySelection) { self.selection = selection }
}

struct PickerScreen: View {
    @ObservedObject var model: PickerModel
    let onFinish: (FamilyActivitySelection?) -> Void

    var body: some View {
        NavigationView {
            FamilyActivityPicker(selection: $model.selection)
                .navigationTitle("Wybierz aplikacje")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Anuluj") { onFinish(nil) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gotowe") { onFinish(model.selection) }
                    }
                }
        }
    }
}