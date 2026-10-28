import Foundation

/// Hardware detection is advisory and never changes saved user preferences.
struct TouchBarSupport: Equatable {
    enum Hardware: Equatable {
        case present, absent, unknown

        static func from(status: Int32?) -> Self {
            // DFR's low bit denotes physical hardware; bit 1 can denote a simulator.
            // Undocumented values must not silently enable system presentation.
            switch status {
            case 0, 2: return .absent
            case 1, 3: return .present
            default: return .unknown
            }
        }
    }
    enum Presentation: Equatable { case systemModal, controlStrip, unavailable }
    let hardware: Hardware
    let presentation: Presentation

    init(hardware: Hardware, fullPresentation: Bool = false, controlStrip: Bool = false) {
        self.hardware = hardware
        presentation = fullPresentation ? .systemModal : (controlStrip ? .controlStrip : .unavailable)
    }

    var isUsable: Bool { hardware == .present && presentation != .unavailable }
    var settingsDescription: String {
        switch hardware {
        case .absent: return "当前使用菜单栏查看额度。"
        case .unknown: return "无法确认 Touch Bar 状态，当前使用菜单栏。"
        case .present:
            return isUsable ? "Touch Bar仅在ChatGPT前台显示；关闭按钮会同步显示开关。"
                : "Touch Bar 系统接口暂不可用，当前使用菜单栏。"
        }
    }
}

@MainActor
protocol TouchBarPresenting: AnyObject {
    func setVisible(_ visible: Bool)
    func update(snapshot: UsageSnapshot?, freshness: SnapshotFreshness, isRefreshing: Bool)
    func updateSessionTPS(_ snapshot: SessionTPSSnapshot, enabled: Bool)
    func applyConfiguration(_ configuration: TouchBarConfiguration)
    func showFeedback(_ message: String)
}

/// Owns only the optional hardware UI. Quota refresh and monitoring never depend on it.
@MainActor
final class TouchBarSession {
    private(set) var controller: (any TouchBarPresenting)?
    private var presentation: TouchBarSupport.Presentation?

    func synchronize(support: TouchBarSupport, enabled: Bool, visible: Bool,
                     makeController: () -> any TouchBarPresenting) {
        guard support.isUsable && enabled else { stop(); return }
        if let presentation, presentation != support.presentation { stop() }
        // Switching away or sleeping must not create a previously unused controller.
        if controller == nil && visible {
            controller = makeController()
            presentation = support.presentation
        }
        controller?.setVisible(visible)
    }

    func stop() {
        controller?.setVisible(false)
        controller = nil
        presentation = nil
    }
}
