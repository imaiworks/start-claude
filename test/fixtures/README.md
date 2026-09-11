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

## 潰し規則の根拠

このフィクスチャは規則を前提に作られているので、**これ自体は「Claude Code が本当にそう潰すか」の検証にならない**
（実装が想定どおり動くかしか分からない）。規則そのものは実データで別途確認した。

| 環境 | 確認内容 |
| --- | --- |
| Linux | 既存の `~/.claude/projects` 6件と突き合わせて一致0件不一致。`.` を含むパスの実例あり |
| Windows | 既存9件と突き合わせて一致（ただし現れた文字は `:` `\` `_` のみ）。`.` は該当パスが無かったため、`%TEMP%\sc.dotcheck\www.example.com\htdocs` を作ってそこで claude を起動し、`.` 3個がすべて `-` になることを確認 |

規則を疑う事態になったら、実データと突き合わせ直すこと。フォルダ名と `cwd` を比べるだけでよい。

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\projects" -Directory | ForEach-Object {
    $log = Get-ChildItem $_.FullName -Filter *.jsonl -File | Select-Object -First 1
    if (-not $log) { return }
    foreach ($line in [System.IO.File]::ReadLines($log.FullName)) {
        $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
        if ($m.Success) {
            $cwd = [regex]::Unescape($m.Groups[1].Value)
            '{0}  {1}' -f $(if (($cwd -replace '[^A-Za-z0-9-]', '-') -ceq $_.Name) { 'OK' } else { 'NG' }), $cwd
            break
        }
    }
}
```

```bash
for d in ~/.claude/projects/*/; do
    f=$(ls "$d"*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    c=$(grep -m1 -oh '"cwd":"[^"]*"' "$f" | sed 's/^"cwd":"//; s/"$//')
    c=${c//\\\\/\\}   # JSON なので '\' は '\\' と書かれている。戻してから比べる
    [ -n "$c" ] || continue
    n=${d%/}; n=${n##*/}
    [ "${c//[!a-zA-Z0-9-]/-}" = "$n" ] && echo "OK  $c" || echo "NG  $c"
done
```

`.` を含むパスが手元に無ければ、そういうディレクトリを作って一度 claude を起動すれば実例が得られる。
