<#
.SYNOPSIS
    過去に Claude Code を起動したディレクトリを一覧表示し、選んだ場所へ移動して claude を起動する。

.DESCRIPTION
    %USERPROFILE%\.claude\projects 配下の各プロジェクトフォルダを走査し、
    セッションログ (*.jsonl) に記録された cwd から実際の作業ディレクトリを復元する。
    フォルダ名は '\' と '_' がどちらも '-' に潰れていて元に戻せないため、
    必ずログ内の cwd を正としている (jsonl が無い場合のみフォルダ名から推測)。

.PARAMETER Filter
    一覧を絞り込むキーワード (パスの部分一致、大文字小文字は区別しない)。

.PARAMETER Last
    一覧を出さずに、最後に使ったディレクトリで即起動する。

.PARAMETER Continue
    claude --continue で起動する (直前の会話を再開)。既定の動作なので通常は省略可。

.PARAMETER New
    --continue を付けず、新しい会話として起動する。

.PARAMETER Resume
    claude --resume で起動する (会話を選んで再開)。

.PARAMETER ProjectsRoot
    走査するルート。既定は %CLAUDE_CONFIG_DIR%\projects
    (未設定なら %USERPROFILE%\.claude\projects)。

.PARAMETER Launcher
    start-claude.bat から呼ばれたときに付く内部用スイッチ。
    「cd だけ」を選んだ際、親プロセスが終了して移動が無駄にならないよう
    その場所で対話シェルを開き直すために使う。

.EXAMPLE
    .\start-claude.ps1

.EXAMPLE
    .\start-claude.ps1 sampleapp -Resume

.EXAMPLE
    # PC を落としてしまった後などに、最後に触っていた場所で会話を再開する
    .\start-claude.ps1 -Last
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Filter,
    [switch]$Last,
    [switch]$Continue,
    [switch]$New,
    [switch]$Resume,
    [string]$ProjectsRoot,
    [switch]$Launcher
)

$ErrorActionPreference = 'Stop'

# --- セッションログ (jsonl) の先頭側から cwd と最初のプロンプトを拾う -----------
function Get-SessionInfo {
    param([string]$JsonlPath)

    $cwd = $null
    $prompt = $null
    $scanned = 0

    try {
        foreach ($line in [System.IO.File]::ReadLines($JsonlPath)) {
            $scanned++

            if (-not $cwd) {
                $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
                if ($m.Success) { $cwd = [regex]::Unescape($m.Groups[1].Value) }
            }

            if (-not $prompt) {
                $m = [regex]::Match($line, '"role":"user","content":"((?:[^"\\]|\\.)*)"')
                if ($m.Success) {
                    $text = [regex]::Unescape($m.Groups[1].Value)
                    $text = ($text -replace '\s+', ' ').Trim()
                    # スラッシュコマンドの展開や system-reminder は見出しに向かないので除外
                    if ($text -and -not $text.StartsWith('<')) { $prompt = $text }
                }
            }

            if ($cwd -and $prompt) { break }
            if ($scanned -ge 400) { break }
        }
    } catch {
        Write-Verbose ('読み取り失敗: {0} ({1})' -f $JsonlPath, $_.Exception.Message)
    }

    return [pscustomobject]@{ Cwd = $cwd; FirstPrompt = $prompt }
}

# --- 実パス -> フォルダ名 と同じ潰し方 ------------------------------------------
#     Claude Code は [a-zA-Z0-9-] 以外をすべて '-' に置き換える。
#     ':' '\' '/' '_' だけでなく '.' も潰れる (example.com -> example-com)。
#     '-' は文字クラスの末尾に置いて範囲指定と解釈されないようにしている。
function ConvertTo-FlatName {
    param([string]$Path)
    return ($Path -replace '[^A-Za-z0-9-]', '-')
}

# --- jsonl が無いときのフォールバック: フォルダ名から推測する -------------------
#     '\' と '_' の区別は失われているので、既知の cwd (とその親) の中から
#     いちばん長く前方一致するものを見つけて、その先だけを '\' で継ぎ足す。
function ConvertFrom-ProjectDirName {
    param(
        [string]$Name,
        [hashtable]$Hints
    )

    if ($Hints) {
        $best = $null
        foreach ($flat in $Hints.Keys) {
            if ($Name.Length -le $flat.Length) { continue }
            if (-not $Name.StartsWith($flat, [StringComparison]::OrdinalIgnoreCase)) { continue }
            # '-' の切れ目で一致していないと別名の途中を拾ってしまう
            if ($Name[$flat.Length] -ne '-') { continue }
            if (-not $best -or $flat.Length -gt $best.Length) { $best = $flat }
        }
        if ($best) {
            $rest = $Name.Substring($best.Length).Trim('-')
            return (Join-Path $Hints[$best] ($rest -replace '-', '\'))
        }
    }

    if ($Name -match '^([A-Za-z])--(.*)$') {
        return ('{0}:\{1}' -f $Matches[1], ($Matches[2] -replace '-', '\'))
    }
    return ($Name -replace '-', '\')
}

function Get-ClaudeProject {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "プロジェクトフォルダが見つかりません: $Root"
    }

    $result = New-Object System.Collections.Generic.List[object]

    # 1st pass: ログから確実な cwd を取る
    foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory) {
        $logs = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)

        $path = $null
        $prompt = $null
        $lastUsed = $dir.LastWriteTime

        if ($logs.Count -gt 0) {
            $lastUsed = $logs[0].LastWriteTime
            foreach ($log in $logs) {
                $info = Get-SessionInfo -JsonlPath $log.FullName
                if ($info.Cwd) {
                    $path = $info.Cwd
                    $prompt = $info.FirstPrompt
                    break
                }
            }
        }

        $result.Add([pscustomobject]@{
            Path        = $path
            LastUsed    = $lastUsed
            Sessions    = $logs.Count
            FirstPrompt = $prompt
            Exists      = $false
            DirName     = $dir.Name
        })
    }

    # 判明した cwd とその親ディレクトリを、名前復元のヒントとして貯める
    $hints = @{}
    foreach ($p in $result) {
        if (-not $p.Path) { continue }
        $current = $p.Path.TrimEnd('\')
        while ($current -and $current -notmatch '^[A-Za-z]:\\?$') {
            $hints[(ConvertTo-FlatName $current)] = $current
            $current = Split-Path -Path $current -Parent
        }
    }

    # 2nd pass: ログが無かったものをヒント付きで推測し、存在確認する
    foreach ($p in $result) {
        if (-not $p.Path) {
            $p.Path = ConvertFrom-ProjectDirName -Name $p.DirName -Hints $hints
        }
        $p.Exists = Test-Path -LiteralPath $p.Path -PathType Container
    }

    return $result | Sort-Object LastUsed -Descending
}

function Get-Ellipsized {
    param([string]$Text, [int]$Width)

    if (-not $Text) { return '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + '...' }
    return $Text
}

function Test-TargetDirectory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Container) { return $true }

    Write-Host ''
    Write-Host "ディレクトリが存在しません: $Path" -ForegroundColor Red
    Write-Host '(ネットワークドライブや WSL のマウントが外れている可能性があります)' -ForegroundColor DarkGray
    return $false
}

# --- claude は起動せず、そのディレクトリに移動するだけ -------------------------
function Enter-DirectoryOnly {
    param([string]$Path)

    if (-not (Test-TargetDirectory -Path $Path)) { return }

    Set-Location -LiteralPath $Path
    Write-Host ''
    Write-Host ("-> {0}" -f $Path) -ForegroundColor Green
    Write-Host '   (claude は起動しません)' -ForegroundColor DarkGray

    if ($Launcher) {
        # bat 経由だとこのプロセスが直後に終わってしまうので、
        # 同じウィンドウで対話シェルを開き直して移動先に留まる。
        $quoted = $Path.Replace("'", "''")
        Write-Host ''
        & powershell.exe -NoLogo -NoProfile -NoExit -Command "Set-Location -LiteralPath '$quoted'"
    }
}

function Start-ClaudeIn {
    param([string]$Path, [string[]]$ClaudeArgs)

    if (-not (Test-TargetDirectory -Path $Path)) { return }

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host 'claude コマンドが PATH に見つかりません。' -ForegroundColor Red
        return
    }

    Set-Location -LiteralPath $Path
    Write-Host ''
    Write-Host ("-> {0}" -f $Path) -ForegroundColor Green
    Write-Host ("-> claude {0}" -f ($ClaudeArgs -join ' ')) -ForegroundColor DarkGray
    Write-Host ''

    if ($ClaudeArgs.Count -gt 0) { & claude @ClaudeArgs } else { & claude }
}

# --- 起動モード ---------------------------------------------------------------
#     既定は continue。PC の再起動や誤ってセッションを閉じた後は
#     「さっきの続きから」が一番よくある使い方なので。
function Get-LaunchArgs {
    param([string]$Mode)

    switch ($Mode) {
        'continue' { return @('--continue') }
        'resume'   { return @('--resume') }
        default    { return @() }
    }
}

function Start-Project {
    param($Project, [string]$Mode)

    # 会話ログが1件も無い場所で --continue しても再開できないので新規に落とす
    if ($Mode -eq 'continue' -and $Project.Sessions -eq 0) {
        Write-Host ''
        Write-Host '  この場所には過去の会話が無いため、新しい会話で起動します。' -ForegroundColor Yellow
        $Mode = 'new'
    }

    Start-ClaudeIn -Path $Project.Path -ClaudeArgs (Get-LaunchArgs -Mode $Mode)
}

# --- 本体 ---------------------------------------------------------------------
if (-not $ProjectsRoot) {
    # Claude Code 本体と同じく CLAUDE_CONFIG_DIR を優先する (sh 版と挙動を合わせる)
    $configDir = $env:CLAUDE_CONFIG_DIR
    if (-not $configDir) { $configDir = Join-Path $env:USERPROFILE '.claude' }
    $ProjectsRoot = Join-Path $configDir 'projects'
}

$projects = @(Get-ClaudeProject -Root $ProjectsRoot)

if ($Filter) {
    $projects = @($projects | Where-Object { $_.Path -like "*$Filter*" -or $_.DirName -like "*$Filter*" })
}

if ($projects.Count -eq 0) {
    Write-Host '該当するプロジェクトがありません。' -ForegroundColor Yellow
    return
}

$defaultMode = 'continue'
if ($New)      { $defaultMode = 'new' }
if ($Continue) { $defaultMode = 'continue' }
if ($Resume)   { $defaultMode = 'resume' }

if ($Last) {
    Start-Project -Project $projects[0] -Mode $defaultMode
    return
}

$modeLabel = switch ($defaultMode) {
    'continue' { '続きから / claude --continue' }
    'resume'   { '会話を選んで再開 / claude --resume' }
    default    { '新しい会話 / claude' }
}

$rule = '-' * 72

Write-Host ''
Write-Host '  Claude Code を起動したことがあるディレクトリ' -ForegroundColor Cyan
Write-Host "  $rule" -ForegroundColor DarkGray

$i = 0
foreach ($p in $projects) {
    $i++
    $mark = '  '
    $color = 'Gray'
    if (-not $p.Exists) {
        $mark = ' x'
        $color = 'DarkGray'
    }

    Write-Host ("{0}{1,3}. {2}  {3,3}件  {4}" -f `
        $mark, $i, $p.LastUsed.ToString('yyyy-MM-dd HH:mm'), $p.Sessions, $p.Path) -ForegroundColor $color

    if ($p.FirstPrompt) {
        Write-Host ('           ' + (Get-Ellipsized -Text $p.FirstPrompt -Width 60)) -ForegroundColor DarkGray
    }
}

Write-Host "  $rule" -ForegroundColor DarkGray
Write-Host ('  番号 = 既定 (' + $modeLabel + ')') -ForegroundColor DarkGray
Write-Host '  番号+c = 続きから / 番号+n = 新しい会話 / 番号+r = 会話を選んで再開' -ForegroundColor DarkGray
Write-Host '  番号+d = そこへ cd するだけ (claude は起動しない)' -ForegroundColor DarkGray
Write-Host '  パスを直接入力してもよい (末尾に半角空白 + n/r/d で同じ指定)。' -ForegroundColor DarkGray
Write-Host '  x 印は今そのディレクトリが無いもの。' -ForegroundColor DarkGray
Write-Host '  空 Enter または q で終了。' -ForegroundColor DarkGray
Write-Host ''

$answer = Read-Host '選択'
if ([string]::IsNullOrWhiteSpace($answer)) { return }
$answer = $answer.Trim()
if ($answer -eq 'q') { return }

function Resolve-Mode {
    param([string]$Suffix, [string]$Default)

    switch -Regex ($Suffix) {
        '[cC]'  { return 'continue' }
        '[nN]'  { return 'new' }
        '[rR]'  { return 'resume' }
        '[dD]'  { return 'cd' }
        default { return $Default }
    }
}

if ($answer -match '^(\d+)\s*([cCnNrRdD])?$') {
    $index = [int]$Matches[1]
    $mode = Resolve-Mode -Suffix $Matches[2] -Default $defaultMode

    if ($index -lt 1 -or $index -gt $projects.Count) {
        Write-Host '番号が範囲外です。' -ForegroundColor Red
        return
    }

    $project = $projects[$index - 1]

    if ($mode -eq 'cd') {
        Enter-DirectoryOnly -Path $project.Path
    } else {
        Start-Project -Project $project -Mode $mode
    }
    return
}

# 数字でなければパス指定とみなす (末尾に半角空白 + c/n/r/d でモード指定)
$typed = $answer.Trim('"')
$mode = $defaultMode
if ($typed -match '^(.*\S)\s+([cCnNrRdD])$') {
    $mode = Resolve-Mode -Suffix $Matches[2] -Default $defaultMode
    $typed = $Matches[1].Trim('"')
}

if ($mode -eq 'cd') {
    Enter-DirectoryOnly -Path $typed
} else {
    Start-ClaudeIn -Path $typed -ClaudeArgs (Get-LaunchArgs -Mode $mode)
}
