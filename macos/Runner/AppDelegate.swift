import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// ウインドウを閉じても終了しない（ドックの件数を出し続け、開き直しを速くする）。終了は⌘Qかメニューから。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// ウインドウを閉じた・最小化した後にドックのアイコンを押したら、ウインドウを出し直す（閉じても破棄しない設定）。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      MainFlutterWindow.shared?.showAgain()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
