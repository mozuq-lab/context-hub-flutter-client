import Cocoa
import FlutterMacOS
import CryptoKit
import UniformTypeIdentifiers
import Darwin
import Security

final class VaultBridge {
  private let fm = FileManager.default
  private let queue = DispatchQueue(label: "context-hub.vault")
  private var channel: FlutterMethodChannel!
  private let folders = ["00_inbox", "10_projects", "20_ideas", "30_knowledge", "40_people", "Input", "90_system"]
  /// Vault直下で読む生成物。共通方針と、本体が生成するふりかえり。
  private let rootFiles = ["POLICY.md", "REVIEW.md"]
  /// 操作journal以外の状態ファイル。保存先の設定、端末に残す書きかけのメモ、選んで深掘りの途中の状態。
  private let nonJournalStates: Set<String> = ["settings.json", "drafts.json", "guided.json", "basket.json", "templates.json"]
  /// キーチェーンに置く秘密の名前。選んで深掘りで使うClaudeのAPIキーだけ。
  private let secretNames: Set<String> = ["anthropic-api-key"]
  private let maxFile = 1_048_576
  /// 読む.md/.jsonの件数、走査する項目（フォルダー・対象外のファイルを含む）の件数、合計バイト数の上限。
  private let maxFiles = 20_000
  private let maxEntries = 100_000
  private let maxTotal = 64 * 1_048_576
  /// 更新時刻の粒度（HFS+は1秒、FAT32は2秒）を見込んで、これより新しいファイルは差分読取で再利用しない。
  private let racyInterval: TimeInterval = 3
  /// attachmentは、ファイルを添える・開く操作の理由（Dartが本人向けの説明にする。Vaultの選び直しを促さない）。
  private enum Failure: Error { case invalid, io, attachment(String) }
  /// 本人がファイル選択画面で選んだ、メモに添えるファイル（参照の名前→場所）。選択画面で選んだファイルは
  /// アプリを閉じるまで読めるため、場所だけを覚える。queueの上でだけ読み書きする。
  private var picked: [String: URL] = [:]

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
      if call.method == "pickAttachment" {
        // メモに添えるファイルを選ぶ。Vaultには触れず、名前・大きさと参照だけを返す。
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.message = "メモに添えるファイル（PDF・画像など）を選んでください。"
        panel.begin { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw Failure.attachment("attachment_not_file") }
            let token = UUID().uuidString
            // 写す操作（queueの上で順に進む）より先に覚える。mainからqueueを待たない（開く操作がmainを待つため）。
            self.queue.async { self.picked[token] = url }
            // Macのファイル名は分解した形（NFD）のことがあるため、合成済みの形にそろえて返す。
            result(["token": token, "name": url.lastPathComponent.precomposedStringWithCanonicalMapping, "bytes": size])
          } catch { result(self.error(error)) }
        }
        return
      }
      if call.method == "openExternal" {
        guard let raw = args["url"] as? String, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { result(error()); return }
        result(NSWorkspace.shared.open(url) ? nil : error()); return
      }
      if call.method == "addToCalendar" {
        // 予定1件のファイルを一時フォルダーに置き、カレンダーで開く。取り込むかは本人がカレンダーで決める。Vaultには触れない。
        guard let ics = args["ics"] as? String, let uid = args["uid"] as? String,
              uid.range(of: "^[0-9a-f]{32}-[a-z]+@context-hub$", options: .regularExpression) != nil else { result(error()); return }
        let name = "contexthub-" + uid.replacingOccurrences(of: "@", with: "-") + ".ics"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
          try ics.data(using: .utf8)!.write(to: url, options: .atomic)
          result(NSWorkspace.shared.open(url) ? nil : self.error())
        } catch { result(self.error()) }
        return
      }
      if call.method == "setDockBadge" {
        // ドックのアイコンに判断待ちの件数を出す。件数だけで、Vaultには触れない。
        let count = args["count"] as? Int ?? 0
        NSApp.dockTile.badgeLabel = count > 0 ? (count > 999 ? "999+" : String(count)) : nil
        result(nil); return
      }
      queue.async {
        do {
          let value = try self.invoke(call.method, args)
          DispatchQueue.main.async { result(value) }
        } catch { DispatchQueue.main.async { result(self.error(error)) } }
      }
    }
  }
  /// ファイルを添える・開く操作の理由はそのコードで返し、ほかはVaultへのアクセスの失敗にする。
  private func error(_ failure: Error) -> FlutterError {
    if case Failure.attachment(let code) = failure { return FlutterError(code: code, message: nil, details: nil) }
    return error()
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
        .appendingPathComponent("ContextHub Client", isDirectory: true)
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
  /// ファイルを読みながら写し、大きさとSHA-256（16進の小文字）を返す。outputが-1なら読むだけ。上限を超えれば失敗。
  private func copyDigest(_ input: Int32, to output: Int32, limit: Int) throws -> (Int, String) {
    var hasher = SHA256(); var total = 0
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let size = Darwin.read(input, &buffer, buffer.count)
      guard size >= 0 else { throw Failure.io }
      if size == 0 { break }
      total += size
      guard total <= limit else { throw Failure.attachment("attachment_too_large") }
      hasher.update(data: Data(buffer[0..<size]))
      if output >= 0 {
        var offset = 0
        while offset < size {
          let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), size - offset) }
          guard written > 0 else { throw Failure.io }; offset += written
        }
      }
    }
    return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }
  private func openRegular(_ path: String, limit: Int) throws -> Int32 {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.attachment("attachment_unreadable") }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Failure.attachment("attachment_not_file") }
    guard st.st_size <= limit else { close(fd); throw Failure.attachment("attachment_too_large") }
    return fd
  }
  /// 選んだファイルをInput/files/<受付ID>へ写す。一時ファイルへ書いてfsyncし、まだない名前へ公開する。
  /// 同じ受付IDのファイルが既にあれば（保存の途中で止まった後の再試行）、内容が同じときだけ使う。
  private func stage(_ root: URL, id: String, source: URL, limit: Int) throws -> [String: Any] {
    let input = try directory(root.appendingPathComponent("Input"), create: true)
    let dir = try directory(input.appendingPathComponent("files"), create: true)
    let target = dir.appendingPathComponent(id)
    let src = try openRegular(source.path, limit: limit)
    defer { close(src) }
    let temp = dir.appendingPathComponent(".ctx-\(UUID().uuidString).tmp")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Failure.io }
    var openFd = true
    defer { if openFd { close(fd) }; unlink(temp.path) }
    let (size, digest) = try copyDigest(src, to: fd, limit: limit)
    guard fsync(fd) == 0, close(fd) == 0 else { throw Failure.io }; openFd = false
    if link(temp.path, target.path) != 0 {
      guard errno == EEXIST else { throw Failure.io }
      guard let existing = try? openRegular(target.path, limit: limit) else { throw Failure.attachment("attachment_conflict") }
      defer { close(existing) }
      // 同じ受付IDに別の内容が既にある（前に写しかけた別のファイル）。Dartは別の操作IDで保存し直す。
      guard let old = try? copyDigest(existing, to: -1, limit: limit), old.0 == size, old.1 == digest else {
        throw Failure.attachment("attachment_conflict")
      }
    }
    try syncDirectory(dir)
    return ["bytes": size, "sha256": digest]
  }
  /// Vault内のメモに添えたファイル（05_files/<年-月>/<キー>/<名前>）の場所。symlinkを経由しない。
  private func vaultFile(_ root: URL, _ path: String) throws -> URL {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts[0] == "05_files",
          parts[1].range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil,
          parts[2].range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil,
          !parts[3].isEmpty, !parts[3].hasPrefix("."), !path.contains("\\") else { throw Failure.invalid }
    var current = root
    for (index, part) in parts.enumerated() {
      current = current.appendingPathComponent(part)
      var st = stat()
      guard lstat(current.path, &st) == 0 else { throw errno == ENOENT ? Failure.attachment("file_missing") : Failure.io }
      let type = st.st_mode & S_IFMT
      guard index < parts.count - 1 ? type == S_IFDIR : type == S_IFREG else { throw Failure.invalid }
    }
    return current
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
  /// Vaultを読む。skipに挙げたパス（フォルダーまたはファイル）は数えず読まない。
  /// knownに前回の更新時刻と大きさ（stamp）が一致するファイルは本文を読まずunchangedに返す。stampは読む前に取る。
  /// 更新時刻が読取開始の直前（racyInterval以内）のファイルはstampを返さない。時刻の粒度が粗い保存先では、
  /// 同じ時刻のうちに同じ大きさで書き換えられても区別できないため、次回も本文を読み直す。
  private func snapshot(_ root: URL, skip: Set<String> = [], known: [String: String] = [:]) throws -> [String: Any] {
    var files = [String: String](); var warnings = [String](); var unchanged = [String](); var stamps = [String: String]()
    var entries = 0; var count = 0; var total = 0; var recognized = false
    let settled = Date().addingTimeInterval(-racyInterval)
    let limitWarning = "読取の上限（ファイル\(maxFiles)件・合計64MB）に達したため、"
    func over() -> Bool { entries > maxEntries || count > maxFiles || total > maxTotal }
    func visit(_ dir: URL, _ prefix: String, _ depth: Int) throws {
      if depth > 12 { warnings.append("深さの上限に達しました。"); return }
      let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
      for entry in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) {
        entries += 1
        if entries > maxEntries { throw Failure.invalid }
        if entry.lastPathComponent.hasPrefix(".") || entry.pathExtension == "tmp" { continue }
        let path = prefix + "/" + entry.lastPathComponent
        if skip.contains(path) { continue }
        let values = try entry.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true { warnings.append("symlinkを除外: " + path); continue }
        if values.isDirectory == true { try visit(try physical(entry), path, depth + 1); continue }
        if !["md", "json"].contains(entry.pathExtension) { continue }
        count += 1
        if count > maxFiles { throw Failure.invalid }
        var stamp: String? = nil
        if let date = values.contentModificationDate, date < settled, let size = values.fileSize {
          stamp = "\(Int64(date.timeIntervalSince1970 * 1000)):\(size)"
        }
        if let stamp = stamp, let size = values.fileSize, known[path] == stamp {
          total += size
          if total > maxTotal { throw Failure.invalid }
          unchanged.append(path); stamps[path] = stamp
          continue
        }
        do {
          let raw = try read(entry)
          total += raw.utf8.count
          if total > maxTotal { throw Failure.invalid }
          files[path] = raw
          if let stamp = stamp { stamps[path] = stamp }
        } catch { warnings.append("読取できないファイル: " + path) }
        if total > maxTotal { throw Failure.invalid }
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
      catch {
        if over() { warnings.append(limitWarning + name + "の一部を読めませんでした。"); break }
        warnings.append("フォルダーの読取を中断: " + name)
      }
    }
    for name in rootFiles {
      let file = root.appendingPathComponent(name)
      if !fm.fileExists(atPath: file.path) { continue }
      count += 1
      do {
        guard count <= maxFiles else { warnings.append(limitWarning + name + "を読めませんでした。"); continue }
        let raw = try read(file)
        total += raw.utf8.count
        guard total <= maxTotal else { warnings.append(limitWarning + name + "を読めませんでした。"); continue }
        files[name] = raw
      } catch { warnings.append("読取できないファイル: " + name) }
    }
    return ["files": files, "warnings": warnings, "recognized": recognized, "unchanged": unchanged, "stamps": stamps]
  }
  /// キーチェーン（ログインキーチェーン）の汎用パスワード項目。サービス名はアプリで固定し、名前で区別する。
  /// 自分でビルドしたアプリでも使えるよう、署名の共有グループが要るデータ保護キーチェーンは使わない。
  private func secretQuery(_ name: String) throws -> [String: Any] {
    guard secretNames.contains(name) else { throw Failure.invalid }
    return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mozuqlab.contexthub",
            kSecAttrAccount as String: name]
  }
  private func invoke(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "readSecret":
      guard let name = args["name"] as? String else { throw Failure.invalid }
      var query = try secretQuery(name)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data,
            let value = String(data: data, encoding: .utf8) else { throw Failure.io }
      return value
    case "writeSecret":
      guard let name = args["name"] as? String, let value = args["value"] as? String,
            !value.isEmpty, value.utf8.count <= 4096 else { throw Failure.invalid }
      let query = try secretQuery(name)
      let data = Data(value.utf8)
      let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "ContextHub Client: Claude API key"
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.io }
      } else if status != errSecSuccess {
        throw Failure.io
      }
      return nil
    case "deleteSecret":
      guard let name = args["name"] as? String else { throw Failure.invalid }
      let query = try secretQuery(name)
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.io }
      return nil
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
        if method == "readSnapshot" {
          let skip = Set((args["skip"] as? [String]) ?? [])
          let known = (args["known"] as? [String: String]) ?? [:]
          return try snapshot(root, skip: skip, known: known)
        }
        if method == "stageAttachment" {
          guard let id = args["requestId"] as? String, id.range(of: "^REQ-[a-f0-9]{32}$", options: .regularExpression) != nil,
                let token = args["token"] as? String,
                let limit = args["maxBytes"] as? Int, limit > 0, handle != "sample" else { throw Failure.invalid }
          guard let source = picked[token] else { throw Failure.attachment("attachment_lost") }
          return try stage(root, id: id, source: source, limit: limit)
        }
        if method == "openVaultFile" {
          // 端末の既定のアプリで開く。Vaultを読める間（security scopeの中）に開いて渡す。
          guard let path = args["path"] as? String, handle != "sample" else { throw Failure.invalid }
          let file = try vaultFile(root, path)
          // 開くとプログラムとして動く種類（実行ファイル・スクリプト・アプリ・場所へのリンク）は開かない（Dartでも名前で断る）。
          if let type = UTType(filenameExtension: file.pathExtension),
             [UTType.executable, .script, .shellScript, .applicationBundle, .application].contains(where: { type.conforms(to: $0) }) {
            throw Failure.attachment("file_launchable")
          }
          let opened = DispatchQueue.main.sync { NSWorkspace.shared.open(file) }
          guard opened else { throw Failure.attachment("file_no_app") }
          return nil
        }
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
