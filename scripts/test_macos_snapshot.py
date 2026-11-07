#!/usr/bin/env python3
"""実Swift読取メソッドをCLTで実行し、一時Vaultの境界を検証する。"""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path('macos/Runner/VaultBridge.swift').read_text()
members = []
for prefix in ['  private let fm ', '  private let folders ', '  private let rootFiles ',
               '  private let maxFile ', '  private let maxFiles ', '  private let maxEntries ',
               '  private let maxTotal ', '  private enum Failure:']:
    members.append(next(line for line in source.splitlines() if line.startswith(prefix)))
for name in ['physical', 'identity', 'directory', 'read', 'syncDirectory', 'snapshot']:
    start = source.index('  private func ' + name + '(')
    end = source.index('\n  private func ', start + 1)
    members.append(source[start:end])
harness = '''
import Cocoa
import Darwin
final class SnapshotUnderTest {
MEMBERS
  func run(_ root: URL, skip: Set<String> = [], known: [String: String] = [:]) throws -> [String: Any] { try snapshot(root, skip: skip, known: known) }
  func identifier(_ root: URL) throws -> String { try identity(root) }
}
let fm = FileManager.default
let base = fm.temporaryDirectory.resolvingSymlinksInPath()
  .appendingPathComponent("context-hub-native-test-" + UUID().uuidString)
try fm.createDirectory(at: base, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: base) }
var failures = [String]()
func check(_ ok: Bool, _ label: String) {
  print((ok ? "PASS: " : "FAIL: ") + label)
  if !ok { failures.append(label) }
}
func root(_ name: String) throws -> URL {
  let url = base.appendingPathComponent(name)
  try fm.createDirectory(at: url.appendingPathComponent("00_inbox"), withIntermediateDirectories: true)
  return url
}
for count in [20000, 20001] {
  let dir = try root("count-\\(count)")
  for i in 0..<count {
    try "架空fixture".write(to: dir.appendingPathComponent("00_inbox/\\(i).md"), atomically: false, encoding: .utf8)
  }
  let result = try SnapshotUnderTest().run(dir)
  check(result["recognized"] as? Bool == true, "件数\\(count): Vault認識と部分表示を保持")
  check((result["files"] as! [String:String]).count == min(count, 20000), "件数\\(count): 20000件の読取上限")
  check((result["warnings"] as! [String]).isEmpty == (count == 20000), "件数\\(count): 上限超過の警告")
  if count > 20000 {
    check((result["warnings"] as! [String]).first?.hasPrefix("読取の上限") == true, "上限超過の警告を区別できる")
  }
}
let skipping = try root("skip")
try fm.createDirectory(at: skipping.appendingPathComponent("90_system/receipts/pending"), withIntermediateDirectories: true)
try "{}".write(to: skipping.appendingPathComponent("90_system/receipts/pending/IN-A.json"), atomically: false, encoding: .utf8)
try "{}".write(to: skipping.appendingPathComponent("90_system/receipts/IN-A.json"), atomically: false, encoding: .utf8)
let skippedResult = try SnapshotUnderTest().run(skipping, skip: ["90_system/receipts/pending"])
check((skippedResult["files"] as! [String:String]).keys.sorted() == ["90_system/receipts/IN-A.json"], "除外したフォルダーは読まない")
let stamps = skippedResult["stamps"] as! [String:String]
check(stamps["90_system/receipts/IN-A.json"] != nil, "読んだファイルの更新時刻と大きさを返す")
let again = try SnapshotUnderTest().run(skipping, skip: ["90_system/receipts/pending"], known: stamps)
check((again["files"] as! [String:String]).isEmpty, "変わっていないファイルは本文を返さない")
check((again["unchanged"] as! [String]) == ["90_system/receipts/IN-A.json"], "変わっていないファイルを示す")
try "{\\"changed\\":true}".write(to: skipping.appendingPathComponent("90_system/receipts/IN-A.json"), atomically: false, encoding: .utf8)
let changed = try SnapshotUnderTest().run(skipping, skip: ["90_system/receipts/pending"], known: stamps)
check((changed["files"] as! [String:String])["90_system/receipts/IN-A.json"] == "{\\"changed\\":true}", "変わったファイルは読み直す")
let capacity = try root("capacity")
let large = String(repeating: "x", count: 1_048_576)
for i in 0..<65 {
  try large.write(to: capacity.appendingPathComponent("00_inbox/\\(i).md"), atomically: false, encoding: .utf8)
}
let capped = try SnapshotUnderTest().run(capacity)
check(capped["recognized"] as? Bool == true, "容量超過: Vault認識と部分表示を保持")
check((capped["files"] as! [String:String]).count == 64, "合計64MiBの読取上限")
check(!(capped["warnings"] as! [String]).isEmpty, "容量超過の警告")
let symlink = try root("symlink")
let outside = base.appendingPathComponent("outside.md")
try "外側の架空fixture".write(to: outside, atomically: false, encoding: .utf8)
try fm.createSymbolicLink(at: symlink.appendingPathComponent("00_inbox/link.md"), withDestinationURL: outside)
try (large + "x").write(to: symlink.appendingPathComponent("00_inbox/oversized.md"), atomically: false, encoding: .utf8)
let excluded = try SnapshotUnderTest().run(symlink)
check(excluded["recognized"] as? Bool == true, "除外があってもVaultを認識")
check((excluded["files"] as! [String:String]).isEmpty, "symlinkと1MiB超ファイルを除外")
check((excluded["warnings"] as! [String]).count == 2, "除外の注意を保持")
let policy = try root("policy")
try "架空の共通方針".write(to: policy.appendingPathComponent("POLICY.md"), atomically: false, encoding: .utf8)
let policyResult = try SnapshotUnderTest().run(policy)
check((policyResult["files"] as! [String:String])["POLICY.md"] == "架空の共通方針", "Vault直下の方針を同じ上限で取得")
try "架空のふりかえり".write(to: policy.appendingPathComponent("REVIEW.md"), atomically: false, encoding: .utf8)
try "読まない直下ファイル".write(to: policy.appendingPathComponent("HOME.md"), atomically: false, encoding: .utf8)
let reviewResult = try SnapshotUnderTest().run(policy)
check((reviewResult["files"] as! [String:String])["REVIEW.md"] == "架空のふりかえり", "Vault直下のふりかえりを同じ上限で取得")
check((reviewResult["files"] as! [String:String])["HOME.md"] == nil, "対象外の直下ファイルは読まない")
let original = try root("identity-original")
let moved = base.appendingPathComponent("identity-moved")
let beforeIdentity = try SnapshotUnderTest().identifier(original)
try fm.moveItem(at: original, to: moved)
check(try SnapshotUnderTest().identifier(moved) == beforeIdentity, "同一フォルダーの移動後もVault識別子を保持")
if !failures.isEmpty { exit(1) }
'''.replace('MEMBERS', '\n'.join(members))
with tempfile.TemporaryDirectory(prefix='context-hub-swift-test-') as work:
    path = Path(work) / 'main.swift'
    path.write_text(harness)
    subprocess.run([os.environ.get('SWIFT_BIN', 'swift'), str(path)], check=True)
