#!/usr/bin/env bash
#
# 過去に Claude Code を起動したディレクトリを一覧表示し、選んだ場所へ移動して claude を起動する。
#
# ~/.claude/projects (CLAUDE_CONFIG_DIR があればそちら) 配下の各プロジェクトディレクトリを走査し、
# セッションログ (*.jsonl) に記録された cwd から実際の作業ディレクトリを復元する。
# ディレクトリ名は '/' '_' '.' などがすべて '-' に潰れていて元に戻せないため、
# 必ずログ内の cwd を正としている (jsonl が無い場合のみディレクトリ名から復元)。
#
#   使い方:  start-claude.sh --help
#
#   「番号+d (cd だけ)」を親シェルに効かせたい場合は source して使う。
#   ~/.bashrc に以下を追記しておくとよい:
#
#       cch() { source /path/to/start-claude.sh "$@"; }
#
#   直接実行した場合は、移動先で対話シェルを開き直すことで代用する。

# source されたか、直接実行されたか
_sc_sourced=0
(return 0 2>/dev/null) && _sc_sourced=1

# --- 実パス -> ディレクトリ名 と同じ潰し方 -------------------------------------
#     Claude Code は [a-zA-Z0-9-] 以外をすべて '-' に置き換える。
#     '/' だけでなく '_' や '.' も潰れる点に注意 (example.com -> example-com)。
#     サブシェルを避けるため結果は _sc_flat に入れる。
_sc_flatten() {
    _sc_flat=${1//[!a-zA-Z0-9-]/-}
}

# --- セッションログ (jsonl) の先頭側から cwd と最初のプロンプトを拾う -----------
#     cwd と最初のユーザー発言はたいてい同じ行に載っているので数行で終わる。
#     見つからない場合でも 400 行で打ち切り、巨大なログで待たされないようにする。
_sc_awk_prog='
function jstr(s, i,   n, c, out) {
    n = length(s); out = ""
    while (i <= n) {
        if (length(out) > 2000) break
        c = substr(s, i, 1)
        if (c == "\"") break
        if (c == "\\") {
            i++
            c = substr(s, i, 1)
            if (c == "n") out = out "\n"
            else if (c == "t") out = out "\t"
            else if (c == "r") out = out "\r"
            else if (c == "b" || c == "f") out = out " "
            else if (c == "u") { out = out "?"; i += 4 }
            else out = out c
            i++
            continue
        }
        out = out c
        i++
    }
    return out
}
{
    if (cwd == "") {
        p = index($0, "\"cwd\":\"")
        if (p > 0) cwd = jstr($0, p + 7)
    }
    if (prompt == "") {
        # tool_result の行は content が配列なのでこのリテラルには一致しない
        p = index($0, "\"role\":\"user\",\"content\":\"")
        if (p > 0) {
            t = jstr($0, p + 25)
            gsub(/[ \t\r\n]+/, " ", t)
            sub(/^ /, "", t); sub(/ $/, "", t)
            # スラッシュコマンドの展開や system-reminder は見出しに向かないので除外
            if (t != "" && substr(t, 1, 1) != "<") prompt = t
        }
    }
    if (cwd != "" && prompt != "") exit
    if (NR >= 400) exit
}
END { printf "%s\t%s\n", cwd, prompt }
'

# $1 = jsonl のパス。結果を _sc_cwd / _sc_prompt に入れる。
_sc_session_info() {
    _sc_cwd=""
    _sc_prompt=""
    IFS=$'\t' read -r _sc_cwd _sc_prompt < <(awk "$_sc_awk_prog" "$1" 2>/dev/null)
}

# --- ディレクトリ名から実パスを復元する (jsonl が無いとき) ---------------------
#     '-' の切れ目が元の '/' なのか '_' や '.' なのか分からないので、
#     '/' から実際のディレクトリを辿りながら、潰した名前が一致する枝を探す。
#     見つかれば実在が保証されたパスになる。
_sc_walk() {
    local base=$1 rest=$2 child name flat
    _sc_steps=$((_sc_steps + 1))
    ((_sc_steps > 4000)) && return 1

    if [[ -z $rest ]]; then
        _sc_walk_result=${base:-/}
        return 0
    fi

    for child in "$base"/*; do
        [[ -d $child ]] || continue
        name=${child##*/}
        _sc_flatten "$name"
        flat=$_sc_flat
        [[ -z $flat ]] && continue
        if [[ $rest == "$flat" ]]; then
            _sc_walk_result=$child
            return 0
        fi
        if [[ $rest == "$flat-"* ]]; then
            _sc_walk "$child" "${rest:${#flat} + 1}" && return 0
        fi
    done
    return 1
}

# $1 = プロジェクトディレクトリ名。結果を _sc_resolved に入れる。
_sc_resolve() {
    local name=$1 flat best rest

    # 1. 実ファイルシステムを辿って復元する (実在するものはこれで確実に当たる)
    _sc_steps=0
    _sc_walk_result=""
    if _sc_walk "" "${name#-}"; then
        _sc_resolved=$_sc_walk_result
        return 0
    fi

    # 2. 既に判明している cwd とその親を手がかりに、最長前方一致で継ぎ足す
    #    (もう存在しないディレクトリはここで拾う)
    best=""
    for flat in "${!_sc_hints[@]}"; do
        [[ ${#name} -le ${#flat} ]] && continue
        [[ $name == "$flat"* ]] || continue
        # '-' の切れ目で一致していないと別名の途中を拾ってしまう
        [[ ${name:${#flat}:1} == "-" ]] || continue
        [[ -z $best || ${#flat} -gt ${#best} ]] && best=$flat
    done
    if [[ -n $best ]]; then
        rest=${name:${#best} + 1}
        _sc_resolved="${_sc_hints[$best]}/${rest//-//}"
        return 0
    fi

    # 3. 最後の手段: '-' をすべて '/' とみなす (先頭の '-' がルートになる)
    _sc_resolved=${name//-//}
}

# --- プロジェクト一覧を集める -------------------------------------------------
_sc_scan() {
    local root=$1 dir name epoch count first
    local -a logfiles entries

    if [[ ! -d $root ]]; then
        printf 'プロジェクトディレクトリが見つかりません: %s\n' "$root" >&2
        return 1
    fi

    _sc_paths=()
    _sc_epochs=()
    _sc_counts=()
    _sc_prompts=()
    _sc_names=()

    # 1st pass: ログから確実な cwd を取る
    for dir in "$root"/*; do
        [[ -d $dir ]] || continue
        name=${dir##*/}

        logfiles=("$dir"/*.jsonl)
        count=${#logfiles[@]}
        _sc_cwd=""
        _sc_prompt=""

        if ((count > 0)); then
            mapfile -t entries < <(stat -c '%Y	%n' -- "${logfiles[@]}" 2>/dev/null | sort -rn)
            epoch=${entries[0]%%$'\t'*}
            for first in "${entries[@]}"; do
                _sc_session_info "${first#*$'\t'}"
                [[ -n $_sc_cwd ]] && break
            done
        else
            epoch=$(stat -c '%Y' -- "$dir" 2>/dev/null)
        fi

        _sc_paths+=("$_sc_cwd")
        _sc_epochs+=("${epoch:-0}")
        _sc_counts+=("$count")
        _sc_prompts+=("$_sc_prompt")
        _sc_names+=("$name")
    done

    # 判明した cwd とその親ディレクトリを、名前復元のヒントとして貯める
    local -i i
    local cur
    local parent
    for ((i = 0; i < ${#_sc_paths[@]}; i++)); do
        cur=${_sc_paths[i]%/}
        while [[ -n $cur && $cur != "/" ]]; do
            _sc_flatten "$cur"
            _sc_hints[$_sc_flat]=$cur
            # '/' を含まないパス (Windows 側が書いた C:\Users\foo など) では
            # ${cur%/*} が縮まないため、進まなくなったら打ち切る
            parent=${cur%/*}
            [[ $parent == "$cur" ]] && break
            cur=$parent
        done
    done

    # 2nd pass: ログが無かったものを復元する
    for ((i = 0; i < ${#_sc_paths[@]}; i++)); do
        if [[ -z ${_sc_paths[i]} ]]; then
            _sc_resolve "${_sc_names[i]}"
            _sc_paths[i]=$_sc_resolved
        fi
    done
}

# --- 表示補助 -----------------------------------------------------------------
_sc_ellipsize() {
    local text=$1 width=$2
    if ((${#text} > width)); then
        _sc_ell="${text:0:width - 1}..."
    else
        _sc_ell=$text
    fi
}

_sc_setup_colors() {
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        _sc_c_reset=$'\033[0m'
        _sc_c_cyan=$'\033[36m'
        _sc_c_gray=$'\033[90m'
        _sc_c_green=$'\033[32m'
        _sc_c_red=$'\033[31m'
        _sc_c_yellow=$'\033[33m'
    else
        _sc_c_reset='' _sc_c_cyan='' _sc_c_gray='' _sc_c_green='' _sc_c_red='' _sc_c_yellow=''
    fi
}

# --- 起動まわり ---------------------------------------------------------------
_sc_check_dir() {
    [[ -d $1 ]] && return 0
    printf '\n%sディレクトリが存在しません: %s%s\n' "$_sc_c_red" "$1" "$_sc_c_reset" >&2
    printf '%s(NFS / sshfs / コンテナのマウントが外れている可能性があります)%s\n' \
        "$_sc_c_gray" "$_sc_c_reset" >&2
    return 1
}

# claude は起動せず、そのディレクトリに移動するだけ
_sc_cd_only() {
    local path=$1
    _sc_check_dir "$path" || return 1

    cd -- "$path" || return 1
    printf '\n%s-> %s%s\n' "$_sc_c_green" "$path" "$_sc_c_reset"
    printf '%s   (claude は起動しません)%s\n' "$_sc_c_gray" "$_sc_c_reset"

    if ((_sc_sourced == 0)); then
        # 直接実行だと親シェルの cwd は変わらないので、ここで対話シェルを開き直す。
        # source して使えば (cch 関数など) この一段は不要になる。
        printf '%s   (source していないため、この場所で新しいシェルを開きます。抜けるには exit)%s\n\n' \
            "$_sc_c_gray" "$_sc_c_reset"
        exec "${SHELL:-/bin/bash}" -i
    fi
}

_sc_run_claude() {
    local path=$1
    shift
    _sc_check_dir "$path" || return 1

    if ! command -v claude >/dev/null 2>&1; then
        printf '%sclaude コマンドが PATH に見つかりません。%s\n' "$_sc_c_red" "$_sc_c_reset" >&2
        return 1
    fi

    cd -- "$path" || return 1
    printf '\n%s-> %s%s\n' "$_sc_c_green" "$path" "$_sc_c_reset"
    printf '%s-> claude %s%s\n\n' "$_sc_c_gray" "$*" "$_sc_c_reset"

    command claude "$@"
}

# 既定は continue。PC の再起動や誤ってセッションを閉じた後は
# 「さっきの続きから」が一番よくある使い方なので。
_sc_launch_args() {
    _sc_args=()
    case $1 in
        continue) _sc_args=(--continue) ;;
        resume) _sc_args=(--resume) ;;
    esac
}

# $1 = 一覧上の添字, $2 = モード
_sc_start_project() {
    local -i idx=$1
    local mode=$2

    # 会話ログが1件も無い場所で --continue しても再開できないので新規に落とす
    if [[ $mode == continue ]] && ((${_sc_counts[idx]} == 0)); then
        printf '\n%s  この場所には過去の会話が無いため、新しい会話で起動します。%s\n' \
            "$_sc_c_yellow" "$_sc_c_reset"
        mode=new
    fi

    _sc_launch_args "$mode"
    _sc_run_claude "${_sc_paths[idx]}" "${_sc_args[@]}"
}

_sc_resolve_mode() {
    case $1 in
        c | C) _sc_mode=continue ;;
        n | N) _sc_mode=new ;;
        r | R) _sc_mode=resume ;;
        d | D) _sc_mode=cd ;;
        *) _sc_mode=$2 ;;
    esac
}

_sc_usage() {
    cat <<'EOF'
使い方: start-claude.sh [キーワード] [オプション]

  過去に Claude Code を起動したディレクトリを一覧から選び、
  その場所へ移動して claude を起動する。

引数:
  キーワード              一覧を絞り込む (パスの部分一致、大文字小文字は区別しない)

オプション:
  -l, --last              一覧を出さずに、最後に使ったディレクトリで即起動する
  -c, --continue          claude --continue で起動する (既定)
  -n, --new               --continue を付けず、新しい会話として起動する
  -r, --resume            claude --resume で起動する (会話を選んで再開)
      --root PATH         走査するルート (既定: ${CLAUDE_CONFIG_DIR:-~/.claude}/projects)
  -h, --help              このヘルプ

例:
  start-claude.sh                   # 一覧から選ぶ
  start-claude.sh sampleapp         # キーワードで絞り込む
  start-claude.sh -l                # 最後に使った場所で続きから
  start-claude.sh -l -n             # 同じ場所で新しい会話
  start-claude.sh webviewer -r      # 絞り込み + 会話を選んで再開

「番号+d (cd だけ)」を親シェルに効かせるには source して使う。
~/.bashrc に以下を追記しておくとよい:

  cch() { source /path/to/start-claude.sh "$@"; }
EOF
}

# --- 本体 ---------------------------------------------------------------------
_sc_main() {
    local filter="" root="" mode="continue" last=0
    local answer typed index suffix rule mark color line_prompt modelabel
    local -i i n

    while (($# > 0)); do
        case $1 in
            -h | --help)
                _sc_usage
                return 0
                ;;
            -l | --last) last=1 ;;
            -c | --continue) mode=continue ;;
            -n | --new) mode=new ;;
            -r | --resume) mode=resume ;;
            --root)
                root=$2
                shift
                ;;
            --root=*) root=${1#--root=} ;;
            -*)
                printf '不明なオプション: %s\n' "$1" >&2
                return 2
                ;;
            *)
                if [[ -z $filter ]]; then
                    filter=$1
                else
                    printf '引数が多すぎます: %s\n' "$1" >&2
                    return 2
                fi
                ;;
        esac
        shift
    done

    if [[ -z $root ]]; then
        root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
    fi

    _sc_setup_colors
    _sc_scan "$root" || return 1

    # 最終利用日時の新しい順に並べ替える
    local -a order
    mapfile -t order < <(
        for ((i = 0; i < ${#_sc_paths[@]}; i++)); do
            printf '%s\t%s\n' "${_sc_epochs[i]}" "$i"
        done | sort -rn -k1,1
    )

    # 絞り込み (パス / ディレクトリ名の部分一致、大文字小文字は区別しない)
    local -a sel=()
    local needle=${filter,,}
    for line_prompt in "${order[@]}"; do
        i=${line_prompt#*$'\t'}
        if [[ -n $needle ]]; then
            [[ ${_sc_paths[i],,} == *"$needle"* || ${_sc_names[i],,} == *"$needle"* ]] || continue
        fi
        sel+=("$i")
    done

    n=${#sel[@]}
    if ((n == 0)); then
        printf '%s該当するプロジェクトがありません。%s\n' "$_sc_c_yellow" "$_sc_c_reset"
        return 1
    fi

    if ((last)); then
        if [[ $mode == cd ]]; then
            _sc_cd_only "${_sc_paths[${sel[0]}]}"
        else
            _sc_start_project "${sel[0]}" "$mode"
        fi
        return
    fi

    case $mode in
        continue) modelabel='続きから / claude --continue' ;;
        resume) modelabel='会話を選んで再開 / claude --resume' ;;
        *) modelabel='新しい会話 / claude' ;;
    esac

    printf -v rule '%0.s-' {1..72}

    printf '\n%s  Claude Code を起動したことがあるディレクトリ%s\n' "$_sc_c_cyan" "$_sc_c_reset"
    printf '%s  %s%s\n' "$_sc_c_gray" "$rule" "$_sc_c_reset"

    for ((i = 0; i < n; i++)); do
        local -i p=${sel[i]}
        mark='  '
        color=''
        if [[ ! -d ${_sc_paths[p]} ]]; then
            mark=' x'
            color=$_sc_c_gray
        fi

        printf '%s%s%3d. %(%Y-%m-%d %H:%M)T  %3d件  %s%s\n' \
            "$color" "$mark" "$((i + 1))" "${_sc_epochs[p]}" \
            "${_sc_counts[p]}" "${_sc_paths[p]}" "$_sc_c_reset"

        if [[ -n ${_sc_prompts[p]} ]]; then
            _sc_ellipsize "${_sc_prompts[p]}" 60
            printf '%s           %s%s\n' "$_sc_c_gray" "$_sc_ell" "$_sc_c_reset"
        fi
    done

    printf '%s  %s\n' "$_sc_c_gray" "$rule"
    printf '  番号 = 既定 (%s)\n' "$modelabel"
    printf '  番号+c = 続きから / 番号+n = 新しい会話 / 番号+r = 会話を選んで再開\n'
    printf '  番号+d = そこへ cd するだけ (claude は起動しない)\n'
    printf '  パスを直接入力してもよい (末尾に半角空白 + n/r/d で同じ指定)。\n'
    printf '  x 印は今そのディレクトリが無いもの。\n'
    printf '  空 Enter または q で終了。%s\n\n' "$_sc_c_reset"

    read -r -p '選択: ' answer || return 0
    answer=${answer#"${answer%%[![:space:]]*}"}
    answer=${answer%"${answer##*[![:space:]]}"}
    [[ -z $answer || $answer == q ]] && return 0

    if [[ $answer =~ ^([0-9]+)[[:space:]]*([cCnNrRdD]?)$ ]]; then
        index=${BASH_REMATCH[1]}
        suffix=${BASH_REMATCH[2]}
        _sc_resolve_mode "$suffix" "$mode"

        if ((index < 1 || index > n)); then
            printf '%s番号が範囲外です。%s\n' "$_sc_c_red" "$_sc_c_reset" >&2
            return 1
        fi

        if [[ $_sc_mode == cd ]]; then
            _sc_cd_only "${_sc_paths[${sel[index - 1]}]}"
        else
            _sc_start_project "${sel[index - 1]}" "$_sc_mode"
        fi
        return
    fi

    # 数字でなければパス指定とみなす (末尾に半角空白 + c/n/r/d でモード指定)
    typed=${answer%\"}
    typed=${typed#\"}
    _sc_mode=$mode
    if [[ $typed =~ ^(.*[^[:space:]])[[:space:]]+([cCnNrRdD])$ ]]; then
        typed=${BASH_REMATCH[1]}
        _sc_resolve_mode "${BASH_REMATCH[2]}" "$mode"
        typed=${typed%\"}
        typed=${typed#\"}
    fi
    typed=${typed/#\~\//$HOME/}

    if [[ $_sc_mode == cd ]]; then
        _sc_cd_only "$typed"
    else
        _sc_launch_args "$_sc_mode"
        _sc_run_claude "$typed" "${_sc_args[@]}"
    fi
}

# --- 実行 ---------------------------------------------------------------------
# nullglob: ログが無いディレクトリで空配列にしたい
# dotglob : 隠しディレクトリも復元の候補に含めたい (.config など)
_sc_saved_glob=$(shopt -p nullglob dotglob)
shopt -s nullglob dotglob

declare -A _sc_hints=()
declare -a _sc_paths=() _sc_epochs=() _sc_counts=() _sc_prompts=() _sc_names=() _sc_args=()

_sc_main "$@"
_sc_rc=$?

eval "$_sc_saved_glob"

# source して使われるので、呼び出し元のシェルに何も残さない
unset -f _sc_flatten _sc_session_info _sc_walk _sc_resolve _sc_scan _sc_ellipsize \
    _sc_setup_colors _sc_check_dir _sc_cd_only _sc_run_claude _sc_launch_args \
    _sc_start_project _sc_resolve_mode _sc_usage _sc_main
unset _sc_awk_prog _sc_hints _sc_paths _sc_epochs _sc_counts _sc_prompts _sc_names \
    _sc_args _sc_flat _sc_cwd _sc_prompt _sc_steps _sc_walk_result _sc_resolved \
    _sc_ell _sc_mode _sc_saved_glob \
    _sc_c_reset _sc_c_cyan _sc_c_gray _sc_c_green _sc_c_red _sc_c_yellow

# _sc_rc は return/exit の引数に必要なので、展開してから自身を unset する
if ((_sc_sourced)); then
    unset _sc_sourced
    eval "unset _sc_rc; return $_sc_rc"
fi
unset _sc_sourced
eval "unset _sc_rc; exit $_sc_rc"
