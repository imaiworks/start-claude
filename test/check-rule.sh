#!/usr/bin/env bash
#
# Claude Code のディレクトリ名の潰し規則が、実データと合っているかを確認する。
#
# run-tests.sh は「実装が仕様どおり動くか」しか見ていない。フィクスチャも規則を
# 前提に作ってあるので、規則そのものの検証にはならない (循環している)。
#
# こちらは ~/.claude/projects の実際のディレクトリ名と、その中の jsonl に記録された
# cwd を突き合わせる。Claude Code が本当にその規則で潰しているかを見る唯一の方法。
#
# 注意: 全件一致しても、cwd に現れなかった文字については何も言えない。
# そのため、実際に現れた「英数字とハイフン以外の文字」を最後に表示する。
# ここに '.' が無ければ、'.' は今回検証されていない。
#
#   使い方: ./test/check-rule.sh [projects のパス]

set -u

root=${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}

if [[ ! -d $root ]]; then
    printf 'プロジェクトディレクトリが見つかりません: %s\n' "$root" >&2
    exit 2
fi

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'
    c_gray=$'\033[90m'; c_yellow=$'\033[33m'
else
    c_reset='' c_red='' c_green='' c_gray='' c_yellow=''
fi

ok=0
ng=0
skipped=0
all_cwd=''

shopt -s nullglob
for dir in "$root"/*/; do
    name=${dir%/}
    name=${name##*/}

    logs=("$dir"*.jsonl)
    if ((${#logs[@]} == 0)); then
        skipped=$((skipped + 1))
        continue
    fi

    cwd=$(grep -m1 -oh '"cwd":"[^"]*"' "${logs[@]}" 2>/dev/null | head -1 | sed 's/^"cwd":"//; s/"$//')
    cwd=${cwd//\\\\/\\}   # JSON なので '\' は '\\' と書かれている
    if [[ -z $cwd ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    all_cwd+=$cwd$'\n'

    # 検証したい規則: [a-zA-Z0-9-] 以外をすべて '-' に置き換える
    flat=${cwd//[!a-zA-Z0-9-]/-}

    if [[ $flat == "$name" ]]; then
        ok=$((ok + 1))
        printf '%sOK   %s%s\n' "$c_gray" "$cwd" "$c_reset"
    else
        ng=$((ng + 1))
        printf '%sNG   %s%s\n' "$c_red" "$cwd" "$c_reset"
        printf '%s     規則から: %s%s\n' "$c_red" "$flat" "$c_reset"
        printf '%s     実際の名: %s%s\n' "$c_red" "$name" "$c_reset"
    fi
done
shopt -u nullglob

printf '\n'
if ((ng == 0)); then
    printf '%s一致 %d件 / 不一致 %d件 / 判定不能 %d件%s\n' "$c_green" "$ok" "$ng" "$skipped" "$c_reset"
else
    printf '%s一致 %d件 / 不一致 %d件 / 判定不能 %d件%s\n' "$c_red" "$ok" "$ng" "$skipped" "$c_reset"
fi

# ブラケット内で '\-' と書くと「'\' と '-'」の意味になり、'\' が報告から漏れる。
# '-' は末尾に置いて範囲指定にならないようにする。
specials=$(printf '%s' "$all_cwd" | grep -o '[^A-Za-z0-9-]' | LC_ALL=C sort -u | tr -d '\n')
printf 'cwd に現れた英数ハイフン以外の文字: %s\n' "${specials:-(なし)}"

if [[ $specials != *.* ]]; then
    printf '\n'
    printf "%s'.' を含むパスが1件も無いため、'.' の潰れ方は「この実行では」検証されていない。%s\\n" "$c_yellow" "$c_reset"
    printf '%s過去に別途確認した記録があるかは test/fixtures/README.md の「潰し規則の根拠」を見ること。%s\n' "$c_yellow" "$c_reset"
    printf "%sこの場で確かめるには、'.' を含むディレクトリを作ってそこで一度 claude を起動し、もう一度これを実行する。%s\\n" "$c_yellow" "$c_reset"
    printf '%s  mkdir -p /tmp/rulecheck/www.example.com%s\n' "$c_gray" "$c_reset"
fi

((ng == 0)) || exit 1
exit 0
