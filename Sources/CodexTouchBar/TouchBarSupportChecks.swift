import Foundation

enum TouchBarSupportChecks {
    static let supported = TouchBarSupport(hardware: .present, fullPresentation: true, controlStrip: true)
    static let fallback = TouchBarSupport(hardware: .present, controlStrip: true)
    static let absent = TouchBarSupport(hardware: .absent)
    static let unknown = TouchBarSupport(hardware: .unknown)

    static func run() -> Bool {
        do {
            try detection()
            try MainActor.assumeIsolated { try lifecycle() }
            print("Touch Bar support self-test passed (hardware states, menu-only lifecycle, recovery, preference gating)")
            return true
        } catch { print("Touch Bar support self-test failed: \(error)"); return false }
    }

    static func detection() throws {
        let check = UsageMonitoringDiagnostics.check
        for raw: Int32 in [0, 2] { try check(TouchBarSupport.Hardware.from(status: raw) == .absent, "no physical hardware, including simulator-only") }
        for raw: Int32 in [1, 3] { try check(TouchBarSupport.Hardware.from(status: raw) == .present, "physical hardware bit") }
        for raw: Int32? in [nil, -1, 4, 5, Int32.max] {
            try check(TouchBarSupport.Hardware.from(status: raw) == .unknown, "unknown values cannot enable hardware UI")
        }
        for hardware in [TouchBarSupport.Hardware.present, .absent, .unknown] {
            for full in [false, true] { for strip in [false, true] {
                let value = TouchBarSupport(hardware: hardware, fullPresentation: full, controlStrip: strip)
                try check(value.isUsable == (hardware == .present && (full || strip)), "API existence is not proof of hardware")
                if full { try check(value.presentation == .systemModal, "full presentation has priority") }
            } }
        }
    }

    @MainActor
    final class Presenter: TouchBarPresenting {
        var visible = false
        var snapshots: [UsageSnapshot?] = []
        func setVisible(_ value: Bool) { visible = value }
        func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, isRefreshing: Bool) { snapshots.append(snapshot) }
        func applyConfiguration(_ configuration: TouchBarConfiguration) {}
        func showFeedback(_ message: String) {}
    }

    @MainActor
    static func lifecycle() throws {
        let check = UsageMonitoringDiagnostics.check
        let session = TouchBarSession()
        var made: [Presenter] = []
        func sync(_ support: TouchBarSupport, enabled: Bool = true, visible: Bool = true) {
            session.synchronize(support: support, enabled: enabled, visible: visible) {
                let presenter = Presenter(); made.append(presenter); return presenter
            }
        }
        // Includes contradictory API flags: absent hardware must always win.
        for support in [absent, unknown, .init(hardware: .present), .init(hardware: .absent, fullPresentation: true)] {
            for visible in [false, true, true, false] {
                sync(support, visible: visible)
                session.controller?.update(snapshot: nil, freshness: .live, isRefreshing: false)
                session.controller?.applyConfiguration(.default)
            }
            session.stop()
        }
        try check(made.isEmpty && session.controller == nil, "menu-only startup, refresh, foreground, sleep and exit never create a controller")
        sync(supported, enabled: false)
        sync(supported, visible: false)
        try check(made.isEmpty, "disabled or inactive launch stays lazy")
        sync(supported); sync(supported)
        try check(made.count == 1 && made[0].visible, "repeated updates reuse a single controller")
        sync(supported, visible: false)
        try check(!made[0].visible, "sleep or foreground loss hides existing presentation")
        sync(supported)
        try check(made.count == 1 && made[0].visible, "wake reuses the controller")
        sync(unknown)
        try check(session.controller == nil && !made[0].visible, "failed detection releases hardware UI")
        sync(supported)
        try check(made.count == 2 && made[1].visible, "confirmed recovery restores UI")
        sync(fallback)
        try check(made.count == 3 && !made[1].visible && made[2].visible, "presentation capability changes replace the old session")
        sync(fallback, enabled: false)
        try check(session.controller == nil && !made[2].visible, "user disabling clears presentation")
        sync(absent); session.stop()
        try check(made.count == 3, "later refresh or termination cannot recreate unsupported UI")
    }
}
