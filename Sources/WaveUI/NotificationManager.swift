// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — macOS desktop notifications for terminal bells / OSC 9 notifications.
// Wraps UNUserNotificationCenter (UserNotifications.framework): requests
// authorization lazily on first post, posts a banner carrying the originating
// window/tab/block in `userInfo`, and routes a click back through `onActivate` so the
// app can focus that window → tab → pane.
//
// UserNotifications requires a bundled `.app` (a proper bundle proxy). Accessing
// `UNUserNotificationCenter.current()` from a non-app process (e.g. an xctest bundle)
// traps, so every entry point first checks `isBundledApp`. Tests never reach this:
// the coordinator's `onDesktopNotification` seam is left nil under test, so the
// suppression/badge logic is exercised without touching UN.

import AppKit
import UserNotifications

/// A pending desktop notification plus the routing identity needed to focus its
/// source pane when clicked. Plain value type so the coordinator (and tests) can
/// build it without importing UserNotifications.
public struct DesktopNotificationRequest: Sendable, Equatable {
    public let title: String?
    public let body: String
    public let blockId: String
    public let tabId: String
    public let windowId: String
    public init(title: String?, body: String, blockId: String, tabId: String, windowId: String) {
        self.title = title
        self.body = body
        self.blockId = blockId
        self.tabId = tabId
        self.windowId = windowId
    }
}

@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    /// userInfo keys carried on each notification (routing identity).
    private enum Key {
        static let blockId = "blockId"
        static let tabId = "tabId"
        static let windowId = "windowId"
    }

    /// Invoked when the user clicks a notification, on the main actor. The composition
    /// root wires this to focus the (window, tab, block).
    public var onActivate: ((_ blockId: String, _ tabId: String, _ windowId: String) -> Void)?

    /// Master gate (mirrors `notification:enabled`). The coordinator already suppresses
    /// disabled notifications before calling `post`, but honoring it here too keeps the
    /// gate authoritative at the single point that talks to the OS.
    public var enabled: Bool = true

    private var didRequestAuthorization = false

    private override init() { super.init() }

    /// Install the delegate (so clicks route to `onActivate`). Call once at launch,
    /// before any notification is posted. No-op outside a bundled `.app`.
    public func configure() {
        guard Self.isBundledApp else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post a desktop notification for a bell / OSC notification. Requests authorization
    /// on first use. No-op when disabled or outside a bundled app.
    public func post(_ request: DesktopNotificationRequest) {
        guard enabled, Self.isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        requestAuthorizationIfNeeded(center)

        let content = UNMutableNotificationContent()
        content.title = request.title ?? Self.appName
        content.body = request.body
        content.sound = .default
        content.userInfo = [
            Key.blockId: request.blockId,
            Key.tabId: request.tabId,
            Key.windowId: request.windowId,
        ]
        // nil trigger ⇒ deliver immediately. A random id keeps each bell distinct.
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    private func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while the app is frontmost (the coordinator has already
    /// decided the pane is not visible, so the user should still see it).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// A click: route to the source pane.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let blockId = info[Key.blockId] as? String
        let tabId = info[Key.tabId] as? String
        let windowId = info[Key.windowId] as? String
        Task { @MainActor in
            if let blockId, let tabId, let windowId {
                self.onActivate?(blockId, tabId, windowId)
            }
            completionHandler()
        }
    }

    // MARK: - Helpers

    /// Whether the running process is a real `.app` bundle. UN APIs trap otherwise.
    private static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wave"
    }
}
