@echo off
rem  Claude Code の過去の作業ディレクトリを選んで起動する
rem  引数はそのまま start-claude.ps1 に渡される (例: start-claude.bat sampleapp -Resume)
rem  -Launcher は「番号+d (cd だけ)」を選んだときに、この窓を閉じずに
rem  移動先でシェルを開き直すための内部用スイッチ
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-claude.ps1" -Launcher %*
