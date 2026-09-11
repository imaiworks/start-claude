# テスト用フィクスチャ

`projects/` は `~/.claude/projects` を模した静的フィクスチャ。マシンに依存しないケースだけを置いてある。
実在するディレクトリを必要とするケース（`.` 入りパスの復元、起動モードの検証）は、実行時に
`run-tests.ps1` / `run-tests.sh` が一時ディレクトリへ生成する。

ここに置いたフォルダはいずれも**実在しないパス**を指す。パス文字列の復元結果そのものを検証するのが目的で、
一覧では `x` 印が付く。

| フォルダ | 表す実パス | 何の回帰テストか |
| --- | --- | --- |
| `C--Users-foo-project` | `C:\Users\foo\project` | `/` を含まないパス。sh 側で親ディレクトリを辿るループが止まらず**無限ループ**になっていた（`f3c9401` で修正）。WSL から `/mnt/c/.../.claude/projects` を覗くと踏む |
| `-tmp-sc-fixture-absent-dev-env-wsl-example-com` | `/tmp/sc-fixture-absent/dev_env_wsl/example.com` | `.` と `_` がどちらも `-` に潰れるケース。`cwd` から実パスが判明するので、下のフォルダを復元するヒントになる |
| `-tmp-sc-fixture-absent-dev-env-wsl-example-com-htdocs` | `/tmp/sc-fixture-absent/dev_env_wsl/example.com/htdocs` | 会話ログ0件（`memory` だけ）のフォルダ。上のヒントから `example.com` の `.` を保ったまま復元できるか。ps1 側で潰し規則が `[:\\/_]` だけだったため失敗していた（`f3c9401` で修正） |

`projects/` 直下の名前は Claude Code の規則（`[a-zA-Z0-9-]` 以外をすべて `-`）で作ってある。
ケースを追加するときも実パスから同じ規則で名前を起こすこと。
