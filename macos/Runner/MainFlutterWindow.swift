import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 前回閉じたときの位置と大きさを、この名前でアプリの設定（UserDefaults）へ記録する。
  private static let frameName = NSWindow.FrameAutosaveName("ContextHubMainWindow")
  private var vaultBridge: VaultBridge?
  private var activeObserver: NSObjectProtocol?
  /// 本人がウインドウを閉じたか。起動直後のまだ出していない状態や、⌘Hで隠した状態とは区別する。
  private var closedByUser = false
  /// 閉じた後に出し直すウインドウ（閉じても破棄しない設定で、アプリが終わるまで残る）。
  private(set) static weak var shared: MainFlutterWindow?

  /// 閉じた・最小化したウインドウを出し直す。
  func showAgain() {
    closedByUser = false
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
  }

  override func close() {
    closedByUser = true
    super.close()
  }
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    // 狭い画面の配置でも上部のボタンが重ならない大きさより小さくしない。
    self.contentMinSize = NSSize(width: 480, height: 420)
    // 記録した位置と大きさがあれば戻す（画面の外にはみ出す場合はAppKitが画面内へ寄せる）。
    // なければ初回の大きさ（サイドバーが出る幅）で、画面の中央に開く。
    if !self.setFrameUsingName(MainFlutterWindow.frameName) {
      var frame = windowFrame
      // 小さい画面では、Dockやメニューバーを除いた範囲に収まるよう縮める。
      if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
      }
      self.setFrame(frame, display: true)
      self.center()
    }
    // 以後、移動・大きさの変更のたびに記録する。
    _ = self.setFrameAutosaveName(MainFlutterWindow.frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    vaultBridge = VaultBridge(flutterViewController.engine.binaryMessenger)
    MainFlutterWindow.shared = self
    // ウインドウを閉じた後に⌘Tabなどでアプリへ切り替えたときも、ウインドウを出し直す（メニューだけが出て操作できない状態にしない）。
    // 最小化している間は、ほかのアプリと同じく最小化したままにする。
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.closedByUser, !self.isVisible else { return }
      self.showAgain()
    }

    super.awakeFromNib()
  }
}
