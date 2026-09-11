<#
.SYNOPSIS
    start-claude.ps1 の回帰テスト。

.DESCRIPTION
    fixtures/projects の静的フィクスチャを一時ディレクトリへ複製し、実在するディレクトリを
    必要とするケースを追加で生成してから、start-claude.ps1 を子プロセスで走らせて出力を検証する。

    claude は PATH の先頭に置いた偽物 (CLAUDE_INVOKED と引数を表示するだけ) に差し替えるので、
    本物の claude は起動しない。

    ハング検出のため、各ケースはタイムアウト付きで実行する。
    パス復元のロジックは sh 版にも同じものがあるので、直したら run-tests.sh も走らせること。

    検証は ASCII の文字列だけで行う。日本語の出力はリダイレクト先のコードページ次第で
    化けたり行が連結されたりするため、判定材料にしない。
    一覧の番号もメニューから読まず、フィクスチャの更新時刻を固定して順序を決め打ちにする。

.EXAMPLE
    .\test\run-tests.ps1

.EXAMPLE
    .\test\run-tests.ps1 -KeepWork   # 成否にかかわらず一時ディレクトリを残す
#>
[CmdletBinding()]
param(
    [int]$TimeoutSec = 60,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $testRoot
$launcher = Join-Path $repoRoot 'start-claude.ps1'

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "start-claude.ps1 が見つかりません: $launcher"
}

$script:passed = 0
$script:failed = 0

function Write-Case {
    param([string]$Name)
    Write-Host ''
    Write-Host ("[ケース] {0}" -f $Name) -ForegroundColor Cyan
}

function Assert-True {
    param([string]$What, [bool]$Condition, [string]$Detail = '')

    if ($Condition) {
        $script:passed++
        Write-Host ("  OK   {0}" -f $What) -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host ("  NG   {0}" -f $What) -ForegroundColor Red
        if ($Detail) {
            foreach ($l in ($Detail -split "`r?`n" | Select-Object -First 8)) {
                Write-Host ("       | {0}" -f $l) -ForegroundColor DarkGray
            }
        }
    }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)
    Assert-True $What ($Expected -ceq $Actual) ("期待 [{0}] / 実際 [{1}]" -f $Expected, $Actual)
}

# 実パス -> フォルダ名。start-claude.ps1 と同じ規則で名前を起こす。
function ConvertTo-FlatName {
    param([string]$Path)
    return ($Path -replace '[^A-Za-z0-9-]', '-')
}

# --- 作業ディレクトリを組み立てる ---------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $work 'projects'
$bin = Join-Path $work 'bin'

New-Item -ItemType Directory -Path $root, $bin -Force | Out-Null
Copy-Item -Path (Join-Path $testRoot 'fixtures\projects\*') -Destination $root -Recurse -Force

# 実在する作業ディレクトリ (途中に '.' を含む) と、その配下の会話ログ0件フォルダ
$live = Join-Path $work 'live\foo.bar\baz'
$liveSub = Join-Path $live 'sub'
New-Item -ItemType Directory -Path $liveSub -Force | Out-Null

$dirLive = Join-Path $root (ConvertTo-FlatName $live)
New-Item -ItemType Directory -Path $dirLive -Force | Out-Null
$logLive = Join-Path $dirLive '00000000-0000-0000-0000-0000000000b1.jsonl'
$cwdJson = $live.Replace('\', '\\')
Set-Content -LiteralPath $logLive -Encoding UTF8 `
    -Value ('{"type":"user","message":{"role":"user","content":"起動テスト用のプロンプト"},"cwd":"' + $cwdJson + '"}')

$dirLiveSub = Join-Path $root (ConvertTo-FlatName $liveSub)
New-Item -ItemType Directory -Path (Join-Path $dirLiveSub 'memory') -Force | Out-Null

# 一覧は最終更新の新しい順に並ぶ。番号を決め打ちにするため明示的に時刻を振る。
# ログがあるフォルダはログの時刻、無いフォルダはフォルダ自身の時刻が使われる。
$base = Get-Date '2026-01-01 12:00:00'
Set-ItemProperty -LiteralPath $logLive -Name LastWriteTime -Value $base
foreach ($d in (Get-ChildItem -LiteralPath $root -Directory)) {
    $logs = @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File)
    if ($d.FullName -eq $dirLiveSub) { Set-ItemProperty -LiteralPath $d.FullName -Name LastWriteTime -Value $base.AddMinutes(-1) }
    elseif ($logs.Count -gt 0 -and $d.FullName -ne $dirLive) {
        Set-ItemProperty -LiteralPath $logs[0].FullName -Name LastWriteTime -Value $base.AddMinutes(-10)
    } elseif ($logs.Count -eq 0 -and $d.FullName -ne $dirLiveSub) {
        Set-ItemProperty -LiteralPath $d.FullName -Name LastWriteTime -Value $base.AddMinutes(-20)
    }
}

# 上の時刻付けで確定する一覧の並び
$IDX_LIVE = 1      # 会話ログ1件・実在・パスに '.' を含む
$IDX_SUB = 2       # 会話ログ0件・実在 ('.' を含む親からヒント復元)
$IDX_ABSENT = 3    # 実在しない (静的フィクスチャのうち最も新しいもの)

# claude の偽物。引数をそのまま見せるので、モード指定の検証に使える。
Set-Content -LiteralPath (Join-Path $bin 'claude.cmd') -Encoding Ascii -Value @(
    '@echo off'
    'echo CLAUDE_INVOKED %*'
)

$env:PATH = $bin + ';' + $env:PATH
Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue

# --- ランチャーを子プロセスで走らせる -----------------------------------------
function Invoke-Launcher {
    param(
        [string]$StdIn = 'q',
        [string[]]$Arguments = @(),
        [switch]$UseConfigDirEnv
    )

    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $work "in-$tag.txt"
    $outFile = Join-Path $work "out-$tag.txt"
    $errFile = Join-Path $work "err-$tag.txt"

    Set-Content -LiteralPath $inFile -Value $StdIn -Encoding Ascii

    $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $launcher + '"'))
    if (-not $UseConfigDirEnv) { $argList += @('-ProjectsRoot', ('"' + $root + '"')) }
    $argList += $Arguments

    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -NoNewWindow -PassThru

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Output = ''; TimedOut = $true }
    }

    $out = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) {
            $out += [string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
        }
    }
    return [pscustomobject]@{ Output = $out; TimedOut = $false }
}

# 偽 claude に渡った引数。起動していなければ $null。
# 一覧のヒント行にも '--continue' の文字が出るので、出力全体を検索してはいけない。
function Get-InvokedArgs {
    param([string]$Output)

    $m = [regex]::Match($Output, 'CLAUDE_INVOKED([^\r\n]*)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

Write-Host ''
Write-Host ('作業ディレクトリ: {0}' -f $work) -ForegroundColor DarkGray

# =============================================================================
Write-Case '一覧が出る / ハングしない'
# '/' を含まない cwd (C:\Users\foo\project) を含んだ状態で完走することを見る。
# sh 側では、このフィクスチャで親を辿るループが止まらず無限ループになっていた。
$menu = Invoke-Launcher -StdIn 'q'
Assert-True 'タイムアウトしない' (-not $menu.TimedOut) ("{0} 秒で終わらなかった" -f $TimeoutSec)
Assert-True "'/' を含まないパスが一覧に出る" ($menu.Output -like '*C:\Users\foo\project*') $menu.Output

# =============================================================================
Write-Case "'.' を含むパスの復元"
# 会話ログがある方は cwd がそのまま出るだけ。ログ0件の方が本題で、
# 判明済みパスをヒントに '.' を保ったまま復元できるかを見る。
Assert-True "cwd の 'foo.bar\baz' がそのまま出る" ($menu.Output -match 'foo\.bar[\\/]baz') $menu.Output
Assert-True "ログ0件フォルダが 'foo.bar\baz\sub' に復元される" `
    ($menu.Output -match 'foo\.bar[\\/]baz[\\/]sub') $menu.Output
Assert-True "静的フィクスチャが 'example.com\htdocs' に復元される" `
    ($menu.Output -match 'example\.com[\\/]htdocs') $menu.Output

# =============================================================================
Write-Case '既定モードは --continue'
$r = Invoke-Launcher -StdIn ([string]$IDX_LIVE)
Assert-Equal '--continue が渡る' '--continue' (Get-InvokedArgs $r.Output)

# =============================================================================
Write-Case '接尾辞 c / n / r / d'
$r = Invoke-Launcher -StdIn ([string]$IDX_LIVE + 'c')
Assert-Equal 'c では --continue が渡る' '--continue' (Get-InvokedArgs $r.Output)

$r = Invoke-Launcher -StdIn ([string]$IDX_LIVE + 'n')
Assert-Equal 'n では引数なしで起動する' '' (Get-InvokedArgs $r.Output)

$r = Invoke-Launcher -StdIn ([string]$IDX_LIVE + 'r')
Assert-Equal 'r では --resume が渡る' '--resume' (Get-InvokedArgs $r.Output)

$r = Invoke-Launcher -StdIn ([string]$IDX_LIVE + 'd')
Assert-True 'd では claude を起動しない' ($null -eq (Get-InvokedArgs $r.Output)) $r.Output
Assert-True 'd では移動先を表示する' ($r.Output -match 'foo\.bar[\\/]baz') $r.Output

# =============================================================================
Write-Case '会話ログ0件の場所では --continue しない'
# --continue は「そのディレクトリの直前の会話」を再開するので、0件だと再開できない。
# 警告を出して新規会話に落とすのが期待動作。
$r = Invoke-Launcher -StdIn ([string]$IDX_SUB)
Assert-Equal '引数なしで起動する (--continue に落ちない)' '' (Get-InvokedArgs $r.Output)

# =============================================================================
Write-Case '存在しないディレクトリは起動しない'
$r = Invoke-Launcher -StdIn ([string]$IDX_ABSENT)
Assert-True 'claude を起動しない' ($null -eq (Get-InvokedArgs $r.Output)) $r.Output

# =============================================================================
Write-Case '番号が範囲外なら起動しない'
$r = Invoke-Launcher -StdIn '999'
Assert-True 'claude を起動しない' ($null -eq (Get-InvokedArgs $r.Output)) $r.Output

# =============================================================================
Write-Case 'キーワードで絞り込める'
$r = Invoke-Launcher -StdIn 'q' -Arguments @('foo.bar')
Assert-True '一致するものだけが出る' `
    (($r.Output -match 'foo\.bar') -and ($r.Output -notlike '*C:\Users\foo\project*')) $r.Output

$r = Invoke-Launcher -StdIn '1' -Arguments @('zzz-no-such-project')
Assert-True '一致しなければ何も起動しない' ($null -eq (Get-InvokedArgs $r.Output)) $r.Output

# =============================================================================
Write-Case 'CLAUDE_CONFIG_DIR を見る'
# sh 版と既定のルートを揃えてある。-ProjectsRoot を渡さずに拾えるかを見る。
$env:CLAUDE_CONFIG_DIR = $work
$r = Invoke-Launcher -StdIn 'q' -UseConfigDirEnv
Remove-Item Env:\CLAUDE_CONFIG_DIR
Assert-True '環境変数の projects を走査する' ($r.Output -match 'foo\.bar[\\/]baz') $r.Output

# =============================================================================
Write-Case 'パスを直接指定できる'
$r = Invoke-Launcher -StdIn ($live + ' n')
Assert-Equal '一覧に無い場所でも指定したモードで起動する' '' (Get-InvokedArgs $r.Output)

$r = Invoke-Launcher -StdIn ($live + ' r')
Assert-Equal '末尾の r が効く' '--resume' (Get-InvokedArgs $r.Output)

$r = Invoke-Launcher -StdIn 'C:\no\such\directory'
Assert-True '存在しないパスでは起動しない' ($null -eq (Get-InvokedArgs $r.Output)) $r.Output

# --- 後始末 -------------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
if ($script:failed -eq 0) {
    Write-Host ("すべて成功: {0} 件" -f $script:passed) -ForegroundColor Green
} else {
    Write-Host ("失敗 {0} 件 / 成功 {1} 件" -f $script:failed, $script:passed) -ForegroundColor Red
}

if ($KeepWork -or $script:failed -gt 0) {
    Write-Host ('作業ディレクトリを残しました: {0}' -f $work) -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) { exit 1 }
exit 0
