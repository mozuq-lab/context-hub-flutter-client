import Cocoa
import FlutterMacOS
import Darwin

final class VaultBridge {
  private let fm = FileManager.default
  private let queue = DispatchQueue(label: "context-hub.vault")
  private var channel: FlutterMethodChannel!
  private let folders = ["00_inbox", "10_projects", "20_ideas", "30_knowledge", "Input", "90_system"]
  /// Vault直下で読む生成物。共通方針と、本体が生成するふりかえり。
  private let rootFiles = ["POLICY.md", "REVIEW.md"]
  /// 操作journal以外の状態ファイル。保存先の設定と、端末に残す書きかけのメモ。
  private let nonJournalStates: Set<String> = ["settings.json", "drafts.json"]
  private let maxFile = 1_048_576
  private enum Failure: Error { case invalid, io }

  init(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.mozuqlab.contexthub/vault", binaryMessenger: messenger)
    channel.setMethodCallHandler { [self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "pickVault" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "同期済みContextHub Vaultを選択してください。"
        panel.begin { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do {
            _ = try self.physical(url)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            result(["handle": "bookmark:" + data.base64EncodedString(), "name": url.lastPathComponent,
                    "identity": try self.identity(url)])
          } catch { result(self.error()) }
        }
        return
      }
      if call.method == "openExternal" {
        guard let raw = args["url"] as? String, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { result(error()); return }
        result(NSWorkspace.shared.open(url) ? nil : error()); return
      }
      queue.async {
        do {
          let value = try self.invoke(call.method, args)
          DispatchQueue.main.async { result(value) }
        } catch { DispatchQueue.main.async { result(self.error()) } }
      }
    }
  }
  private func error() -> FlutterError {
    FlutterError(code: "vault_access", message: "Vaultへアクセスできません。権限・保存先・確認情報を確認し、必要ならフォルダーを再選択してください。", details: nil)
  }
  private func appData() throws -> URL {
    let base: URL
    if let path = ProcessInfo.processInfo.environment["CONTEXT_HUB_APP_DATA"], !path.isEmpty {
      base = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("ContextHub Flutter", isDirectory: true)
    }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    return try physical(base)
  }
  private func physical(_ url: URL) throws -> URL {
    let normalized = url.standardizedFileURL
    guard normalized.path == normalized.resolvingSymlinksInPath().path else { throw Failure.invalid }
    let values = try normalized.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw Failure.invalid }
    return normalized
  }
  private func identity(_ url: URL) throws -> String {
    let dir = try directory(url)
    var st = stat()
    guard lstat(dir.path, &st) == 0 else { throw Failure.io }
    let volume = try dir.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
      ?? "device-\(st.st_dev)"
    return "mac:\(volume):\(st.st_ino)"
  }
  private func root(_ handle: String, _ action: (URL) throws -> Any?) throws -> Any? {
    if handle == "sample" { return try action(physical(appData().appendingPathComponent("sample-vault"))) }
    guard handle.hasPrefix("bookmark:"), let data = Data(base64Encoded: String(handle.dropFirst(9))) else { throw Failure.invalid }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, url.startAccessingSecurityScopedResource() else { throw Failure.invalid }
    defer { url.stopAccessingSecurityScopedResource() }
    return try action(physical(url))
  }
  private func validRelative(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return rootFiles.contains(path) || parts.count > 1 && parts.count <= 13 && folders.contains(String(parts[0])) &&
      !path.contains("\\") && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && $0 != ".." }
  }
  private func directory(_ url: URL, create: Bool = false) throws -> URL {
    if !fm.fileExists(atPath: url.path), create {
      try fm.createDirectory(at: url, withIntermediateDirectories: false)
      try syncDirectory(url.deletingLastPathComponent())
    }
    let resolved = try physical(url)
    guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.invalid }
    return resolved
  }
  private func read(_ url: URL, limit: Int = 1_048_576) throws -> String {
    _ = try physical(url)
    var st = stat()
    guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit else { throw Failure.invalid }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let size = Darwin.read(fd, &buffer, buffer.count)
      guard size >= 0 else { throw Failure.io }
      if size == 0 { break }
      data.append(contentsOf: buffer.prefix(size))
      guard data.count <= limit else { throw Failure.invalid }
    }
    guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
    return text
  }
  private func syncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
    guard fsync(fd) == 0 else { throw Failure.io }
  }
  private func write(_ url: URL, raw: String, exclusive: Bool) throws {
    let parent = try directory(url.deletingLastPathComponent())
    let data = Data(raw.utf8)
    guard data.count <= maxFile else { throw Failure.invalid }
    let temp = parent.appendingPathComponent(".ctx-\(UUID().uuidString).tmp")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Failure.io }
    var openFd = true
    defer { if openFd { close(fd) }; unlink(temp.path) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let size = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard size > 0 else { throw Failure.io }; offset += size
      }
    }
    guard fsync(fd) == 0, close(fd) == 0 else { throw Failure.io }; openFd = false
    if exclusive {
      guard link(temp.path, url.path) == 0 else { throw Failure.io }
      guard unlink(temp.path) == 0 else { throw Failure.io }
    } else {
      if fm.fileExists(atPath: url.path) { _ = try physical(url) }
      guard rename(temp.path, url.path) == 0 else { throw Failure.io }
    }
    try syncDirectory(parent)
  }
  private func stateFile(_ name: String) throws -> URL {
    guard nonJournalStates.contains(name) || name.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.json$", options: .regularExpression) != nil else { throw Failure.invalid }
    return try directory(appData().appendingPathComponent("state"), create: true).appendingPathComponent(name)
  }
  private func snapshot(_ root: URL) throws -> [String: Any] {
    var files = [String: String](); var warnings = [String](); var count = 0; var total = 0; var recognized = false
    func visit(_ dir: URL, _ prefix: String, _ depth: Int) throws {
      if depth > 12 { warnings.append("深さの上限に達しました。"); return }
      for entry in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) {
        count += 1
        if count > 5000 { throw Failure.invalid }
        if entry.lastPathComponent.hasPrefix(".") || entry.pathExtension == "tmp" { continue }
        let path = prefix + "/" + entry.lastPathComponent
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true { warnings.append("symlinkを除外: " + path); continue }
        if values.isDirectory == true { try visit(try physical(entry), path, depth + 1); continue }
        if !["md", "json"].contains(entry.pathExtension) { continue }
        do {
          let raw = try read(entry)
          total += raw.utf8.count
          if total > 64 * 1_048_576 { throw Failure.invalid }
          files[path] = raw
        } catch { warnings.append("読取できないファイル: " + path) }
        if total > 64 * 1_048_576 { throw Failure.invalid }
      }
    }
    for name in folders {
      let dir = root.appendingPathComponent(name)
      if !fm.fileExists(atPath: dir.path) { continue }
      do {
        let checked = try directory(dir)
        recognized = true
        try visit(checked, name, 1)
      }
      catch { warnings.append("フォルダーの読取を中断: " + name); if count > 5000 || total > 64 * 1_048_576 { break } }
    }
    for name in rootFiles {
      let file = root.appendingPathComponent(name)
      if !fm.fileExists(atPath: file.path) { continue }
      count += 1
      do {
        guard count <= 5000 else { throw Failure.invalid }
        let raw = try read(file)
        total += raw.utf8.count
        guard total <= 64 * 1_048_576 else { throw Failure.invalid }
        files[name] = raw
      } catch { warnings.append("読取できないファイル: " + name) }
    }
    return ["files": files, "warnings": warnings, "recognized": recognized]
  }
  private func invoke(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "sampleVault":
      guard let files = args["files"] as? [String: String], files.count <= 5000 else { throw Failure.invalid }
      guard files.values.reduce(0, { $0 + $1.utf8.count }) <= 64 * maxFile else { throw Failure.invalid }
      let sample = try appData().appendingPathComponent("sample-vault")
      if !fm.fileExists(atPath: sample.path) {
        let staging = try appData().appendingPathComponent(".sample-\(UUID().uuidString).tmp")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for folder in folders { try fm.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: false) }
        for (path, raw) in files where validRelative(path) {
          let file = staging.appendingPathComponent(path)
          try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try write(file, raw: raw, exclusive: true)
        }
        try fm.moveItem(at: staging, to: sample)
        try syncDirectory(sample.deletingLastPathComponent())
      }
      _ = try physical(sample)
      return ["handle": "sample", "name": "架空サンプル", "identity": try identity(sample)]
    case "readState":
      guard let name = args["name"] as? String else { throw Failure.invalid }
      let file = try stateFile(name)
      return fm.fileExists(atPath: file.path) ? try read(file, limit: 65_536) : nil
    case "writeState":
      guard let name = args["name"] as? String, let raw = args["raw"] as? String, raw.utf8.count <= 65_536 else { throw Failure.invalid }
      try write(stateFile(name), raw: raw, exclusive: args["exclusive"] as? Bool == true); return nil
    case "listJournals":
      let state = try stateFile("settings.json").deletingLastPathComponent()
      return try fm.contentsOfDirectory(atPath: state.path).filter { !nonJournalStates.contains($0) && !$0.hasPrefix(".") }
    default:
      guard let handle = args["handle"] as? String else { throw Failure.invalid }
      return try root(handle) { root in
        if method == "readSnapshot" { return try snapshot(root) }
        guard ["readRequest", "writeRequest"].contains(method), let id = args["requestId"] as? String,
              id.range(of: "^REQ-[a-f0-9]{32}$", options: .regularExpression) != nil else { throw Failure.invalid }
        let input = root.appendingPathComponent("Input")
        if method == "readRequest", !fm.fileExists(atPath: input.path) { return nil }
        let dir = try directory(input, create: method == "writeRequest")
        let file = dir.appendingPathComponent(id + ".md")
        if method == "readRequest" { return fm.fileExists(atPath: file.path) ? try read(file) : nil }
        guard let raw = args["raw"] as? String, raw.utf8.count <= 40_192 else { throw Failure.invalid }
        try write(file, raw: raw, exclusive: true)
        guard try read(file) == raw else { throw Failure.io }; return nil
      }
    }
  }
}
