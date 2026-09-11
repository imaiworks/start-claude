# start-claude

過去に Claude Code を起動したディレクトリを一覧から選び、その場所へ移動して `claude` を起動するランチャー。Windows (PowerShell) 版と Linux (bash) 版がある。

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
| `start-claude.ps1` | Windows 用の本体 |
| `start-claude.bat` | cmd / ダブルクリック用のラッパー。引数はそのまま ps1 に渡る |
| `start-claude.sh` | Linux 用の本体 |

一覧の作り方も操作も両者で揃えてあるので、以降の説明は特記がなければ共通。

## 使い方

### Windows

```powershell
.\start-claude.ps1                  # 一覧から選ぶ
.\start-claude.ps1 sampleapp        # キーワードで絞り込む
.\start-claude.ps1 -Last            # 一覧を出さず、最後に使った場所で続きから
.\start-claude.ps1 -Last -New       # 同じ場所で新しい会話
.\start-claude.ps1 webviewer -Resume  # 絞り込み + 会話を選んで再開
.\start-claude.ps1 -ProjectsRoot C:\path\to\projects  # 走査するルートを指定
```

### Linux

```bash
./start-claude.sh                   # 一覧から選ぶ
./start-claude.sh sampleapp         # キーワードで絞り込む
./start-claude.sh -l                # 一覧を出さず、最後に使った場所で続きから
./start-claude.sh -l -n             # 同じ場所で新しい会話
./start-claude.sh webviewer -r      # 絞り込み + 会話を選んで再開
./start-claude.sh --root /path/to/projects  # 走査するルートを指定
```

オプションは `-l/--last` `-c/--continue` `-n/--new` `-r/--resume` `-h/--help`。

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

**Windows**: PowerShell から `.\start-claude.ps1` として実行した場合、`d` を選ぶとスクリプト終了後もその場所に留まる（ドットソース不要）。

`start-claude.bat` 経由だと子プロセスなので普通に `cd` しても無駄になる。そのため bat は内部スイッチ `-Launcher` を渡しており、`d` のときは同じウィンドウで移動先の対話シェルを開き直す。

**Linux**: 子プロセスからは親シェルの cwd を変えられないので、`source` して使う。`~/.bashrc` に関数をひとつ足しておくのがいちばん楽。

```bash
cch() { source /path/to/start-claude.sh "$@"; }
```

これで `cch` から `3d` を選ぶと、そのシェル自身が移動する。`source` せずに `./start-claude.sh` として直接実行した場合は、移動先で対話シェルを開き直して代用する（抜けるには `exit`）。

スクリプトは自分が `source` されたかを検出して動きを変え、終了時に内部で使った関数と変数をすべて `unset` するので、呼び出し元のシェルには何も残らない。`nullglob` / `dotglob` も元の設定に戻す。

## 仕組み

`.claude/projects`（`CLAUDE_CONFIG_DIR` があればそちら）にある各プロジェクトフォルダを走査するが、**フォルダ名から元のパスは復元できない**。Claude Code は `[a-zA-Z0-9-]` 以外の文字をすべて `-` に置き換えるので、区切りの `\` `/` も `_` も `.` も、区別がつかなくなっている。

```
Z--home-user-dev-env-wsl-webviewer        -home-user-dev-env-wsl-example-com
  ↓ 実体は                                  ↓ 実体は
Z:\home\user\dev_env_wsl\webviewer        /home/user/dev_env_wsl/example.com
```

そこでセッションログ `*.jsonl` の各行に記録されている `cwd` フィールドを正としてパスを取得している。ログは行単位で読み、`cwd` と最初のプロンプトが見つかった時点で打ち切るので、10MB を超えるログでも待たされない（実測: 16 プロジェクト・最大 2.7MB のログを含めて 0.1 秒未満）。

会話ログが1件も残っていないフォルダ（`memory` だけ残っている場合）は `cwd` が取れないので、次の順に復元する。

1. **実ファイルシステムを辿る**（Linux 版のみ）。`/` から順に、各階層の実在するディレクトリ名を同じ規則で潰して、フォルダ名の続きと一致する枝を選ぶ。当たれば実在が保証されたパスになり、`.` や `_` 入りのディレクトリ名も正しく戻る
2. **判明済みのパスから推測する**。他プロジェクトで分かった実パスとその親ディレクトリを手がかりに、最長前方一致でパスを組み立てる。上の例が分かっていれば `Z--home-user-dev-env-wsl-todoapp` も `Z:\home\user\dev_env_wsl\todoapp` として正しく復元できる。すでに消えたディレクトリはここで拾う
3. どちらも当たらなければ、`-` をそのまま区切りとみなす

また、会話ログが0件の場所で `--continue` しても再開できないので、その場合は警告を出して自動的に新しい会話へフォールバックする。

## 動作要件

### Windows

- Windows PowerShell 5.1 以降（`powershell.exe`）
- `claude` が PATH に通っていること。見つからない場合は起動前にその旨を表示する

### Linux

- bash 4.2 以降（連想配列と `printf '%(...)T'` を使っている）
- `awk` / `stat` / `sort`（coreutils と gawk・mawk いずれか）。それ以外の外部コマンドは使わない
- `claude` が PATH に通っていること。見つからない場合は起動前にその旨を表示する

## メモ

- `start-claude.ps1` は **UTF-8 BOM 付き** で保存する。Windows PowerShell 5.1 は BOM が無いスクリプトを ANSI として読むため、日本語が文字化けする
- `start-claude.bat` は BOM 無し・CRLF。BOM 付きだと cmd.exe が1行目の解釈に失敗することがある
- `start-claude.sh` は BOM 無し・LF。CRLF だと shebang の解釈に失敗し、ヒアドキュメントの終端も一致しなくなる
- 改行は `.gitattributes` で `*.bat` / `*.cmd` / `*.ps1` を `eol=crlf`、`*.sh` を `eol=lf` に固定している。LF だけの `.bat` は cmd.exe がラベルや `goto` を誤読することがあるため
- PowerShell 5.1 からこのリポジトリのファイルを作るときは `-Encoding utf8` を明示する（`>` や `Out-File` の既定は UTF-16LE で、Git がバイナリ扱いしてしまう）
- 潰し規則は ps1 / sh のどちらも `[a-zA-Z0-9-]` 以外をすべて `-` にする実装で揃えてある。ここを `[:\\/_]` だけにすると `C:\dev\foo.bar\baz` のように `.` を含むパスでログ0件フォルダの復元（上記 2.）が外れる

## どこからでも呼びたいとき

Windows は PATH の通ったフォルダに置くか、PowerShell プロファイルに関数を足す。

```powershell
function cch { & 'C:\tools\start-claude\start-claude.ps1' @args }
```

Linux は `~/.bashrc` に関数を足す。`d`（cd だけ）を効かせるために、PATH に置くのではなく `source` する形にしておくこと。

```bash
cch() { source ~/tools/start-claude/start-claude.sh "$@"; }
```
