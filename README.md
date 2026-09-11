# start-claude

過去に Claude Code を起動したディレクトリを一覧から選び、その場所へ移動して `claude` を起動する Windows 用ランチャー。

PC を再起動したあとや、うっかりセッションを閉じてしまったあとに「どこで作業していたか」を思い出して `cd` するのが面倒、というのを解消するためのもの。既定の動作は `claude --continue`（そのディレクトリの直前の会話を再開）。

以下は表示例（パスはすべて架空のもの）。

```
  Claude Code を起動したことがあるディレクトリ
  ------------------------------------------------------------------------
    1. 2026-09-11 11:51    1件  Z:\home\user\dev_env_wsl\webviewer
           このページみたいな仕組みって作れないかな？まず構成を調べたい
    2. 2026-09-11 11:51    2件  Z:\home\user\dev_env_wsl\monitoring
           こんにちは
    3. 2026-09-10 20:51    1件  C:\Users\user\projects\sampleapp
           こんにちは！
  ------------------------------------------------------------------------
  番号 = 既定 (続きから / claude --continue)
  番号+c = 続きから / 番号+n = 新しい会話 / 番号+r = 会話を選んで再開
  番号+d = そこへ cd するだけ (claude は起動しない)
```

## ファイル

| ファイル | 用途 |
| --- | --- |
| `start-claude.ps1` | 本体 |
| `start-claude.bat` | cmd / ダブルクリック用のラッパー。引数はそのまま ps1 に渡る |

## 使い方

```powershell
.\start-claude.ps1                  # 一覧から選ぶ
.\start-claude.ps1 sampleapp        # キーワードで絞り込む
.\start-claude.ps1 -Last            # 一覧を出さず、最後に使った場所で続きから
.\start-claude.ps1 -Last -New       # 同じ場所で新しい会話
.\start-claude.ps1 webviewer -Resume  # 絞り込み + 会話を選んで再開
```

一覧が出たあとの入力:

| 入力 | 動作 |
| --- | --- |
| `3` | 3番のディレクトリで `claude --continue`（既定） |
| `3c` | 同上（明示指定） |
| `3n` | 新しい会話として起動 |
| `3r` | `claude --resume`（会話をピッカーで選ぶ） |
| `3d` | そこへ `cd` するだけ。`claude` は起動しない |
| `C:\path\to\dir` | 一覧に無い場所を直接指定（末尾に半角空白 + `c`/`n`/`r`/`d` でモード指定） |
| 空 Enter / `q` | 終了 |

`-Continue` / `-New` / `-Resume` をコマンドラインで渡すと、番号だけを入力したときの既定モードが変わる。

### 一覧の見方

- 最終利用日時の新しい順。件数はそのディレクトリに残っている会話ログの数
- パスの下の淡い行は、その会話の最初のプロンプトの抜粋
- 行頭の `x` は、そのディレクトリが今は存在しないもの（ネットワークドライブや WSL のマウントが外れている等）。選んでも起動せず警告するだけ

### cd だけの挙動について

PowerShell から `.\start-claude.ps1` として実行した場合、`d` を選ぶとスクリプト終了後もその場所に留まる（ドットソース不要）。

`start-claude.bat` 経由だと子プロセスなので普通に `cd` しても無駄になる。そのため bat は内部スイッチ `-Launcher` を渡しており、`d` のときは同じウィンドウで移動先の対話シェルを開き直す。

## 仕組み

`%USERPROFILE%\.claude\projects` にある各プロジェクトフォルダを走査するが、**フォルダ名から元のパスは復元できない**。`\` も `_` もどちらも `-` に潰されているため。

```
Z--home-user-dev-env-wsl-webviewer
  ↓ 実体は
Z:\home\user\dev_env_wsl\webviewer
```

そこでセッションログ `*.jsonl` の各行に記録されている `cwd` フィールドを正としてパスを取得している。ログは行単位で読み、`cwd` と最初のプロンプトが見つかった時点で打ち切るので、10MB を超えるログでも待たされない。

会話ログが1件も残っていないフォルダ（`memory` だけ残っている場合）は `cwd` が取れないため、他プロジェクトで判明した実パスとその親ディレクトリを手がかりに、最長前方一致でパスを組み立てる。上の例が分かっていれば `Z--home-user-dev-env-wsl-todoapp` も `Z:\home\user\dev_env_wsl\todoapp` として正しく復元できる。

また、会話ログが0件の場所で `--continue` しても再開できないので、その場合は警告を出して自動的に新しい会話へフォールバックする。

## 動作要件

- Windows PowerShell 5.1 以降（`powershell.exe`）
- `claude` が PATH に通っていること。見つからない場合は起動前にその旨を表示する

## メモ

- `start-claude.ps1` は **UTF-8 BOM 付き** で保存する。Windows PowerShell 5.1 は BOM が無いスクリプトを ANSI として読むため、日本語が文字化けする
- `start-claude.bat` は BOM 無し・CRLF。BOM 付きだと cmd.exe が1行目の解釈に失敗することがある
- 改行は `.gitattributes` で `*.bat` / `*.cmd` / `*.ps1` を `eol=crlf` に固定している。LF だけの `.bat` は cmd.exe がラベルや `goto` を誤読することがあるため
- PowerShell 5.1 からこのリポジトリのファイルを作るときは `-Encoding utf8` を明示する（`>` や `Out-File` の既定は UTF-16LE で、Git がバイナリ扱いしてしまう）

## どこからでも呼びたいとき

PATH の通ったフォルダに置くか、PowerShell プロファイルに関数を足す。

```powershell
function cch { & 'C:\tools\start-claude\start-claude.ps1' @args }
```
