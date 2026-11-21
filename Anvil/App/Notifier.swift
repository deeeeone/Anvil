import AppKit
import UserNotifications

/// macOS notifications only when they matter: the agent needs you (approval, question) or finished, and Anvil isn't
/// the app in front. Approvals carry Allow and Decline buttons; questions take a typed reply.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var handlers: [String: (String, String?) -> Void] = [:]
    /// Called when a notification is clicked (to bring up the right session).
    var onOpen: ((String) -> Void)?
    private var ready = false

    func setup() {
        guard !ready, !AppInfo.isTesting else { return }
        ready = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "approval", actions: [allow, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: "question", actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "done", actions: [], intentIdentifiers: []),
        ])
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var appIsInFront: Bool { NSApp?.isActive ?? true }

    /// `handler(actionID, typedText)`: actionID is "allow", "decline", "reply" or "open".
    func post(id: String, title: String, body: String, category: String, session: String, handler: ((String, String?) -> Void)? = nil) {
        guard ready, !appIsInFront else { return }
        if let handler { handlers[id] = handler }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Fmt.plain(body)
        content.categoryIdentifier = category
        content.userInfo = ["session": session]
        content.sound = category == "done" ? nil : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The prompt was answered in the app: take the notification away.
    func withdraw(_ id: String) {
        handlers[id] = nil
        guard ready else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let session = response.notification.request.content.userInfo["session"] as? String ?? ""
        Task { @MainActor in
            let a = action == UNNotificationDefaultActionIdentifier ? "open" : action
            if a == "open" {
                NSApp.activate(ignoringOtherApps: true)
                self.onOpen?(session)
            } else {
                self.handlers.removeValue(forKey: id)?(a, text)
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])   // Anvil is in front: the in-app card is enough
    }
}
