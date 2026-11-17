import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 前回閉じたときの位置と大きさを、この名前でアプリの設定（UserDefaults）へ記録する。
  private static let frameName = NSWindow.FrameAutosaveName("ContextHubMainWindow")
  private var vaultBridge: VaultBridge?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    // 狭い画面の配置でも上部のボタンが重ならない大きさより小さくしない。
    self.contentMinSize = NSSize(width: 480, height: 420)
    // 記録した位置と大きさがあれば戻す（画面の外にはみ出す場合はAppKitが画面内へ寄せる）。
    // なければ初回の大きさ（サイドバーが出る幅）で、画面の中央に開く。
    if !self.setFrameUsingName(MainFlutterWindow.frameName) {
      self.setFrame(windowFrame, display: true)
      self.center()
    }
    // 以後、移動・大きさの変更のたびに記録する。
    self.setFrameAutosaveName(MainFlutterWindow.frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    vaultBridge = VaultBridge(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
