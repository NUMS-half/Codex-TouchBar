import AppKit
import ObjectiveC

/// Allows offscreen lifecycle checks without presenting UI or touching system state.
struct TouchBarPresentationAccess {
    var present: (NSTouchBar) -> Bool
    var dismiss: (NSTouchBar) -> Void
    var register: (NSCustomTouchBarItem) -> Bool
    var setPresence: (String, Bool) -> Void
    var unregister: (NSCustomTouchBarItem) -> Void

    static let system = Self(present: TouchBarSystem.present, dismiss: TouchBarSystem.dismiss,
                             register: TouchBarSystem.register, setPresence: TouchBarSystem.setControlStripPresence,
                             unregister: TouchBarSystem.unregister)
}

/// All private entry points are resolved at runtime. Probing never enables a simulator.
enum TouchBarSystem {
    private static let dfrHandle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW
    )
    private static let presentSelector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let addSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeSelector = NSSelectorFromString("removeSystemTrayItem:")
    private typealias StatusFunction = @convention(c) () -> Int32
    private typealias PresenceFunction = @convention(c) (CFString, ObjCBool) -> Void
    private static let getStatus: StatusFunction? = {
        guard let dfrHandle, let symbol = dlsym(dfrHandle, "DFRGetStatus") else { return nil }
        return unsafeBitCast(symbol, to: StatusFunction.self)
    }()
    private static let setPresence: PresenceFunction? = {
        guard let dfrHandle, let symbol = dlsym(dfrHandle, "DFRElementSetControlStripPresenceForIdentifier") else { return nil }
        return unsafeBitCast(symbol, to: PresenceFunction.self)
    }()

    static func detect() -> TouchBarSupport {
        let hardware = TouchBarSupport.Hardware.from(status: getStatus?())
        guard hardware == .present else { return TouchBarSupport(hardware: hardware) }
        return TouchBarSupport(hardware: hardware, fullPresentation: supportsFullPresentation, controlStrip: supportsControlStrip)
    }

    static var supportsFullPresentation: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil
            && class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }
    static var supportsControlStrip: Bool {
        setPresence != nil
            && (NSTouchBarItem.self as AnyObject).responds(to: addSelector)
            && (NSTouchBarItem.self as AnyObject).responds(to: removeSelector)
    }

    static func present(_ touchBar: NSTouchBar) -> Bool {
        guard supportsFullPresentation,
              let method = class_getClassMethod(NSTouchBar.self, presentSelector) else { return false }
        typealias PresentFunction = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: PresentFunction.self)
        // Placement 0 preserves the right-side macOS Control Strip; 1 replaces it.
        function(NSTouchBar.self, presentSelector, touchBar, 0, "com.wyx.CodexTouchBar.system-modal" as NSString)
        return true // The API has no result confirming physical display.
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias DismissFunction = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: DismissFunction.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
    }

    static func register(_ item: NSCustomTouchBarItem) -> Bool {
        guard supportsControlStrip else { return false }
        _ = (NSTouchBarItem.self as AnyObject).perform(addSelector, with: item)
        return true
    }
    static func setControlStripPresence(_ identifier: String, _ visible: Bool) {
        setPresence?(identifier as CFString, ObjCBool(visible))
    }
    static func unregister(_ item: NSCustomTouchBarItem) {
        guard (NSTouchBarItem.self as AnyObject).responds(to: removeSelector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(removeSelector, with: item)
    }
}
