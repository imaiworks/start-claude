<#
.SYNOPSIS
    Claude Code のフォルダ名の潰し規則が、実データと合っているかを確認する。

.DESCRIPTION
    run-tests.ps1 は「実装が仕様どおり動くか」しか見ていない。フィクスチャも規則を
    前提に作ってあるので、規則そのものの検証にはならない (循環している)。

    こちらは `~/.claude/projects` の実際のフォルダ名と、その中の jsonl に記録された
    cwd を突き合わせる。Claude Code が本当にその規則で潰しているかを見る唯一の方法。

    注意: 全件一致しても、cwd に現れなかった文字については何も言えない。
    そのため、実際に現れた「英数字とハイフン以外の文字」を最後に表示する。
    ここに '.' が無ければ、'.' は今回検証されていない。

.EXAMPLE
    .\test\check-rule.ps1

.EXAMPLE
    .\test\check-rule.ps1 -ProjectsRoot D:\backup\projects
#>
[CmdletBinding()]
param([string]$ProjectsRoot)

$ErrorActionPreference = 'Stop'

if (-not $ProjectsRoot) {
    $configDir = $env:CLAUDE_CONFIG_DIR
    if (-not $configDir) { $configDir = Join-Path $env:USERPROFILE '.claude' }
    $ProjectsRoot = Join-Path $configDir 'projects'
}

if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
    Write-Host "プロジェクトフォルダが見つかりません: $ProjectsRoot" -ForegroundColor Red
    exit 2
}

$ok = 0
$ng = 0
$skipped = 0
$seen = @{}

foreach ($dir in Get-ChildItem -LiteralPath $ProjectsRoot -Directory) {
    $log = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { $skipped++; continue }

    $cwd = $null
    foreach ($line in [System.IO.File]::ReadLines($log.FullName)) {
        $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { $cwd = [regex]::Unescape($m.Groups[1].Value); break }
    }
    if (-not $cwd) { $skipped++; continue }

    foreach ($c in $cwd.ToCharArray()) {
        if ($c -notmatch '[A-Za-z0-9-]') { $seen[$c] = $true }
    }

    # 検証したい規則: [a-zA-Z0-9-] 以外をすべて '-' に置き換える
    $flat = $cwd -replace '[^A-Za-z0-9-]', '-'

    if ($flat -ceq $dir.Name) {
        $ok++
        Write-Host ("OK   {0}" -f $cwd) -ForegroundColor DarkGray
    } else {
        $ng++
        Write-Host ("NG   {0}" -f $cwd) -ForegroundColor Red
        Write-Host ("     規則から: {0}" -f $flat) -ForegroundColor Red
        Write-Host ("     実際の名: {0}" -f $dir.Name) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ("一致 {0}件 / 不一致 {1}件 / 判定不能 {2}件" -f $ok, $ng, $skipped) `
    -ForegroundColor $(if ($ng -eq 0) { 'Green' } else { 'Red' })

$specials = ($seen.Keys | Sort-Object) -join ' '
Write-Host ("cwd に現れた英数ハイフン以外の文字: {0}" -f $(if ($specials) { $specials } else { '(なし)' }))

if (-not $seen.ContainsKey('.')) {
    Write-Host ''
    Write-Host "'.' を含むパスが1件も無いため、'.' の潰れ方はこの実行では検証されていない。" -ForegroundColor Yellow
    Write-Host "確かめるには、'.' を含むディレクトリを作ってそこで一度 claude を起動し、もう一度これを実行する。" -ForegroundColor Yellow
    Write-Host '  mkdir "$env:TEMP\rulecheck\www.example.com"' -ForegroundColor DarkGray
}

if ($ng -gt 0) { exit 1 }
exit 0
