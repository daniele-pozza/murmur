import AppKit
import ApplicationServices

// Reproduces TextInjector's insert seam outside the app, so paste failures in a
// specific target app (Brave) can be driven and observed from the terminal.
//
//   injecttest "text"    AX probe + pasteboard + ⌘V + AX re-read verdict
//   injecttest --read    print role + value of the focused AX element
//
// Tagged [INJTEST] so output is greppable.

func frontmost() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
    guard status == .success, let focused else { return nil }
    return unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
}

func readField(_ el: AXUIElement) -> (role: String, value: String?) {
    var role: CFTypeRef?
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
    return (role as? String ?? "?", value as? String)
}

func postCommandV() {
    guard let source = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else {
        print("[INJTEST] could not create CGEvents")
        return
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    print("[INJTEST] ⌘V posted (flags=maskCommand, tap=cghidEventTap)")
}

if CommandLine.arguments.contains("--read") {
    print("[INJTEST] frontmost=\(frontmost()) trusted=\(AXIsProcessTrusted())")
    guard let el = focusedElement() else {
        print("[INJTEST] read: no focused element")
        exit(0)
    }
    let (role, value) = readField(el)
    print("[INJTEST] read: role=\(role) value=\(value.map { "\"\($0)\"" } ?? "nil")")
    exit(0)
}

let args = CommandLine.arguments
guard args.count > 1, !args[1].hasPrefix("--") else {
    print("usage: injecttest \"text\" | --read")
    exit(2)
}
let text = args[1]
print("[INJTEST] frontmost=\(frontmost()) trusted=\(AXIsProcessTrusted())")

guard let el = focusedElement() else {
    print("[INJTEST] AX: no focused element")
    exit(0)
}

var settable: DarwinBoolean = false
guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
      settable.boolValue else {
    print("[INJTEST] AX: selected text not settable — would fall back to paste; doing it")
    pasteTest(el)
    exit(0)
}
print("[INJTEST] AX: selected text IS settable here (unexpected for Chromium)")
exit(0)

func pasteTest(_ el: AXUIElement) {
    let (_, before) = readField(el)

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    print("[INJTEST] pasteboard set (\(text.count) chars)")

    Thread.sleep(forTimeInterval: 0.04)
    postCommandV()

    Thread.sleep(forTimeInterval: 0.6)
    guard let el2 = focusedElement() else {
        print("[INJTEST] VERDICT: focused element gone after paste")
        return
    }
    let (_, after) = readField(el2)
    switch (before, after) {
    case (_, nil):
        print("[INJTEST] VERDICT: unreadable (before=\(before.map { "\"\($0)\"" } ?? "nil"), after=nil)")
    case (nil, _):
        print("[INJTEST] VERDICT: was unreadable before, now readable len=\(after?.count ?? -1)")
    case (let b?, let a?):
        if a.contains(text) && a != b {
            print("[INJTEST] VERDICT: LANDED (field \(b.count)→\(a.count) chars)")
        } else if a == b {
            print("[INJTEST] VERDICT: UNCHANGED (field still \(a.count) chars) — paste dropped")
        } else {
            print("[INJTEST] VERDICT: changed but marker missing (field \(b.count)→\(a.count) chars)")
        }
    }
}
