#!/usr/bin/env bash
#
# start-claude.sh の回帰テスト。
#
# fixtures/projects の静的フィクスチャを一時ディレクトリへ複製し、実在するディレクトリを
# 必要とするケースを追加で生成してから、start-claude.sh を走らせて出力を検証する。
#
# claude は PATH の先頭に置いた偽物 (CLAUDE_INVOKED と引数を表示するだけ) に差し替えるので、
# 本物の claude は起動しない。
#
# ハング検出のため、各ケースは timeout 付きで実行する。
# パス復元のロジックは ps1 版にも同じものがあるので、直したら run-tests.ps1 も走らせること。
#
# 判定は ASCII の文字列だけで行い、一覧の番号もメニューから読まない
# (フィクスチャの更新時刻を固定して順序を決め打ちにする)。run-tests.ps1 と同じ方針。
#
#   使い方: ./test/run-tests.sh [--keep]

set -u

TIMEOUT=${TIMEOUT:-60}
keep=0
[[ ${1:-} == --keep ]] && keep=1

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(dirname -- "$test_root")
launcher=$repo_root/start-claude.sh

if [[ ! -f $launcher ]]; then
    printf 'start-claude.sh が見つかりません: %s\n' "$launcher" >&2
    exit 1
fi

passed=0
failed=0

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'
    c_red=$'\033[31m'; c_gray=$'\033[90m'
else
    c_reset='' c_cyan='' c_green='' c_red='' c_gray=''
fi

case_of() { printf '\n%s[ケース] %s%s\n' "$c_cyan" "$1" "$c_reset"; }

ok() {
    passed=$((passed + 1))
    printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"
}

ng() {
    failed=$((failed + 1))
    printf '  %sNG%s   %s\n' "$c_red" "$c_reset" "$1"
    if [[ -n ${2:-} ]]; then
        printf '%s' "$2" | head -8 | while IFS= read -r l; do
            printf '       %s| %s%s\n' "$c_gray" "$l" "$c_reset"
        done
    fi
}

assert_rc_eq() { # $1 説明, $2 期待する終了コード, $3 実際, $4 詳細
    if (($2 == $3)); then ok "$1"; else ng "$1" "期待 rc=$2 / 実際 rc=$3"$'\n'"${4:-}"; fi
}

assert_rc_ne() { # $1 説明, $2 避けたい終了コード, $3 実際, $4 詳細
    if (($2 != $3)); then ok "$1"; else ng "$1" "rc=$3 になってはいけない"$'\n'"${4:-}"; fi
}

assert_match() { # $1 説明, $2 正規表現, $3 対象
    if [[ $3 =~ $2 ]]; then ok "$1"; else ng "$1" "$3"; fi
}

assert_not_match() {
    if [[ ! $3 =~ $2 ]]; then ok "$1"; else ng "$1" "$3"; fi
}

# 実パス -> ディレクトリ名。start-claude.sh の _sc_flatten と同じ規則。
flatten() { printf '%s' "${1//[!a-zA-Z0-9-]/-}"; }

# --- 作業ディレクトリを組み立てる ---------------------------------------------
work=$(mktemp -d "${TMPDIR:-/tmp}/sc-test-XXXXXX")
root=$work/projects
bin=$work/bin
mkdir -p "$root" "$bin"
cp -R "$test_root/fixtures/projects/." "$root/"

# 実在する作業ディレクトリ (途中に '.' を含む) と、その配下の会話ログ0件ディレクトリ
live=$work/live/foo.bar/baz
live_sub=$live/sub
mkdir -p "$live_sub"

dir_live=$root/$(flatten "$live")
mkdir -p "$dir_live"
log_live=$dir_live/00000000-0000-0000-0000-0000000000b1.jsonl
printf '%s\n' \
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"起動テスト用のプロンプト\"},\"cwd\":\"$live\"}" \
    > "$log_live"

dir_live_sub=$root/$(flatten "$live_sub")
mkdir -p "$dir_live_sub/memory"

# 見出しに使うプロンプトが最新ログには無く、古いログにだけある場合
two=$work/twolog
mkdir -p "$two"
dir_two=$root/$(flatten "$two")
mkdir -p "$dir_two"
log_two_old=$dir_two/00000000-0000-0000-0000-0000000000c1.jsonl
log_two_new=$dir_two/00000000-0000-0000-0000-0000000000c2.jsonl
printf '%s\n' \
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"older-log-prompt\"},\"cwd\":\"$two\"}" \
    > "$log_two_old"
printf '%s\n' "{\"type\":\"system\",\"cwd\":\"$two\"}" > "$log_two_new"

# 一覧は最終更新の新しい順に並ぶ。番号を決め打ちにするため明示的に時刻を振る。
# ログがあるディレクトリはログの時刻、無いディレクトリは自身の時刻が使われる。
stamp() { touch -d "$1" -- "$2"; }
stamp '2026-01-01 12:00:00' "$log_live"
stamp '2026-01-01 11:30:00' "$log_two_new"
stamp '2026-01-01 11:29:00' "$log_two_old"

for d in "$root"/*; do
    [[ -d $d ]] || continue
    [[ $d == "$dir_live" || $d == "$dir_two" || $d == "$dir_live_sub" ]] && continue
    shopt -s nullglob
    logs=("$d"/*.jsonl)
    shopt -u nullglob
    if ((${#logs[@]} > 0)); then
        stamp '2026-01-01 11:50:00' "${logs[0]}"
    else
        stamp '2026-01-01 11:40:00' "$d"
    fi
done
# ディレクトリの時刻は中身を作った後に振る (子を作ると親の時刻が更新されるため)
stamp '2026-01-01 11:59:00' "$dir_live_sub"

# 上の時刻付けで確定する一覧の並び
IDX_LIVE=1    # 会話ログ1件・実在・パスに '.' を含む
IDX_SUB=2     # 会話ログ0件・実在 ('.' を含む親からヒント復元)
IDX_ABSENT=3  # 実在しない (静的フィクスチャのうち最も新しいもの)

# claude の偽物。引数をそのまま見せるので、モード指定の検証に使える。
cat > "$bin/claude" <<'SHIM'
#!/bin/sh
echo "CLAUDE_INVOKED $*"
SHIM
chmod +x "$bin/claude"

PATH=$bin:$PATH
export PATH
unset CLAUDE_CONFIG_DIR

# --- ランチャーを走らせる -----------------------------------------------------
# $1 = 標準入力に流す文字列, 以降 = ランチャーへの引数。_out と _rc に結果を入れる。
run_launcher() {
    local input=$1
    shift
    _out=$(printf '%s\n' "$input" | timeout "$TIMEOUT" bash "$launcher" --root "$root" "$@" 2>&1)
    _rc=$?
}

# 既定のルート (CLAUDE_CONFIG_DIR 経由) で走らせる
run_launcher_env() {
    local input=$1
    shift
    _out=$(printf '%s\n' "$input" | CLAUDE_CONFIG_DIR=$work timeout "$TIMEOUT" bash "$launcher" "$@" 2>&1)
    _rc=$?
}

# 偽 claude に渡った引数を _args に入れる。起動していなければ 1 を返す。
# 一覧のヒント行にも '--continue' の文字が出るので、出力全体を検索してはいけない。
invoked_args() {
    local line
    line=$(printf '%s\n' "$_out" | grep -m1 '^CLAUDE_INVOKED') || return 1
    line=${line#CLAUDE_INVOKED}
    # 前後の空白を落とす
    line=${line#"${line%%[![:space:]]*}"}
    _args=${line%"${line##*[![:space:]]}"}
    return 0
}

assert_args() { # $1 説明, $2 期待する引数
    if invoked_args && [[ $_args == "$2" ]]; then
        ok "$1"
    else
        ng "$1" "期待 [$2] / 実際 [${_args-未起動}]"$'\n'"$_out"
    fi
}

assert_not_invoked() { # $1 説明
    if invoked_args; then ng "$1" "$_out"; else ok "$1"; fi
}

printf '\n%s作業ディレクトリ: %s%s\n' "$c_gray" "$work" "$c_reset"

# =============================================================================
case_of '一覧が出る / ハングしない'
# cwd が 'C:\Users\foo\project' (= '/' を含まない) のフィクスチャを含んだ状態で完走するか。
# 親ディレクトリを辿るヒント収集ループが、ここで無限ループになっていた。
run_launcher q
menu=$_out
assert_rc_ne "タイムアウトしない (${TIMEOUT}s)" 124 "$_rc" "$menu"
assert_match "'/' を含まないパスが一覧に出る" 'C:\\Users\\foo\\project' "$menu"

# =============================================================================
case_of "'.' を含むパスの復元"
assert_match "cwd の 'foo.bar/baz' がそのまま出る" 'foo\.bar/baz' "$menu"
assert_match "ログ0件ディレクトリが 'foo.bar/baz/sub' に復元される" 'foo\.bar/baz/sub' "$menu"
assert_match "静的フィクスチャが 'example.com/htdocs' に復元される" 'example\.com/htdocs' "$menu"

# =============================================================================
case_of '既定モードは --continue'
run_launcher "$IDX_LIVE"
assert_args '--continue が渡る' '--continue'

# =============================================================================
case_of '接尾辞 c / n / r'
run_launcher "${IDX_LIVE}c"
assert_args 'c では --continue が渡る' '--continue'

run_launcher "${IDX_LIVE}n"
assert_args 'n では引数なしで起動する' ''

run_launcher "${IDX_LIVE}r"
assert_args 'r では --resume が渡る' '--resume'

# =============================================================================
case_of '接尾辞 d (source した場合は親シェルの cwd が変わる)'
# 直接実行すると移動先で対話シェルを開き直す作りなので、cd の確認は source 側で行う。
cd_out=$(
    cd -- "$work" || exit 1
    printf '%s\n' "${IDX_LIVE}d" | {
        source "$launcher" --root "$root" > /dev/null 2>&1
        pwd
    }
)
assert_match 'cd 先が foo.bar/baz になる' 'foo\.bar/baz$' "$cd_out"

# =============================================================================
case_of '会話ログ0件の場所では --continue しない'
# --continue は「そのディレクトリの直前の会話」を再開するので、0件だと再開できない。
# 警告を出して新規会話に落とすのが期待動作。
run_launcher "$IDX_SUB"
assert_args '引数なしで起動する (--continue に落ちない)' ''

# =============================================================================
case_of '存在しないディレクトリは起動しない'
run_launcher "$IDX_ABSENT"
assert_not_invoked 'claude を起動しない'

# =============================================================================
case_of '番号が範囲外なら起動しない'
run_launcher 999
assert_not_invoked 'claude を起動しない'

# =============================================================================
case_of 'キーワードで絞り込める'
run_launcher q foo.bar
assert_match '一致するものが出る' 'foo\.bar' "$_out"
assert_not_match '一致しないものは出ない' 'C:\\Users\\foo\\project' "$_out"

run_launcher 1 zzz-no-such-project
assert_not_invoked '一致しなければ何も起動しない'

# =============================================================================
case_of 'CLAUDE_CONFIG_DIR を見る'
run_launcher_env q
assert_match '環境変数の projects を走査する' 'foo\.bar/baz' "$_out"

# =============================================================================
case_of '見出しのプロンプトは古いログからも拾う'
# 最新ログに cwd しか無い場合でも、古いログから最初のプロンプトを探す。
assert_match '古いログのプロンプトが一覧に出る' 'older-log-prompt' "$menu"

# =============================================================================
case_of '--cd / --last'
cd_out=$(
    cd -- "$work" || exit 1
    printf '\n' | {
        source "$launcher" --root "$root" --last --cd > /dev/null 2>&1
        pwd
    }
)
assert_match 'cd 先が foo.bar/baz になる' 'foo\.bar/baz$' "$cd_out"

run_launcher '' --last --cd
assert_not_invoked 'claude を起動しない'

# =============================================================================
case_of '--root に値が無ければエラー'
# 黙って既定のルートを見てしまうと、別の場所の一覧が出て分かりにくい。
_out=$(printf 'q\n' | timeout "$TIMEOUT" bash "$launcher" --root 2>&1); _rc=$?
assert_rc_ne '正常終了しない' 0 "$_rc" "$_out"
assert_match '値が必要である旨を出す' '値が必要' "$_out"

_out=$(printf 'q\n' | timeout "$TIMEOUT" bash "$launcher" --root= 2>&1); _rc=$?
assert_rc_ne '--root= (空) も弾く' 0 "$_rc" "$_out"

# =============================================================================
case_of 'パスを直接指定できる'
run_launcher "$live n"
assert_args '一覧に無い場所でも指定したモードで起動する' ''

run_launcher "$live r"
assert_args '末尾の r が効く' '--resume'

run_launcher /no/such/directory
assert_not_invoked '存在しないパスでは起動しない'

# =============================================================================
case_of '--help / 不明なオプション'
_out=$(timeout "$TIMEOUT" bash "$launcher" --help 2>&1); _rc=$?
assert_rc_eq '--help が 0 で終わる' 0 "$_rc" "$_out"
assert_match '使い方が出る' '使い方' "$_out"

_out=$(timeout "$TIMEOUT" bash "$launcher" --no-such-option 2>&1); _rc=$?
assert_rc_ne '不明なオプションは非0で終わる' 0 "$_rc" "$_out"

# --- 後始末 -------------------------------------------------------------------
printf '\n%s%s%s\n' "$c_gray" "------------------------------------------------------------" "$c_reset"
if ((failed == 0)); then
    printf '%sすべて成功: %d 件%s\n' "$c_green" "$passed" "$c_reset"
else
    printf '%s失敗 %d 件 / 成功 %d 件%s\n' "$c_red" "$failed" "$passed" "$c_reset"
fi

if ((keep == 1 || failed > 0)); then
    printf '%s作業ディレクトリを残しました: %s%s\n' "$c_gray" "$work" "$c_reset"
else
    rm -rf -- "$work"
fi

((failed == 0)) || exit 1
exit 0
