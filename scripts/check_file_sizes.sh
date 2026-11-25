#!/bin/bash
# lib/ 以下のDartファイルが目安の行数を超えていないかを確かめる。
# 超えたファイルは警告として示すだけで、検証は止めない（GitHub Actionsでは注釈として出る）。
# 機能を足すときは、同じファイルに追記し続けずに、画面・ダイアログ・機能ごとのファイルに分ける（AGENTS.mdの「コード構成」）。
set -euo pipefail
cd "$(dirname "$0")/.."
limit="${DART_FILE_LINES_LIMIT:-1500}"
over=0
while IFS= read -r -d '' file; do
  lines=$(wc -l < "$file")
  if (( lines > limit )); then
    over=$((over + 1))
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::warning file=$file::${lines}行あります（目安は${limit}行）。機能ごとのファイルに分けることを検討してください。"
    else
      echo "警告: $file は${lines}行あります（目安は${limit}行）。機能ごとのファイルに分けることを検討してください。" >&2
    fi
  fi
done < <(find lib -name '*.dart' -print0 | sort -z)
if (( over == 0 )); then
  echo "lib/ のDartファイルはすべて${limit}行以内です。"
fi
