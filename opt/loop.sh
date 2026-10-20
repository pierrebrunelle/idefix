#!/bin/bash
# opt loop — karpathy/autoresearch pattern for max.
# A workspace is a git repo containing: program.md (what to optimize) and
# score.sh (prints one float). Each iteration: max mutates the artifact,
# score.sh measures, git keeps or discards. One scalar, one loop, one file
# of experiments.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${1:?usage: loop.sh <workspace> [iters]}" || exit 1
ITERS="${2:-${OPT_N:-100}}"
AGENT="${MAX_AGENT:-$REPO/max}"
DIR="${OPT_DIRECTION:-min}"   # min: lower score wins; max: higher wins

[ -f program.md ] || { echo "missing program.md"; exit 1; }
[ -x score.sh ] || { echo "missing executable score.sh"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || git init -q
mkdir -p logs

better() {  # better NEW BEST -> exit 0 if new improves on best
  awk -v n="$1" -v b="$2" -v d="$DIR" 'BEGIN{exit !(d=="min" ? n<b : n>b)}'
}

score() { ./score.sh 2>/dev/null | tail -1; }

best="$(score)"
echo "baseline score: $best" | tee experiments.tsv
echo -e "iter\tscore\tbest\tverdict" >> experiments.tsv

for i in $(seq 1 "$ITERS"); do
  git add -A && git commit -qm "iter $((i-1)) end" --allow-empty
  "$AGENT" --repo . --instructions program.md \
    --max-requests "${OPT_MAX_REQ:-15}" --max-seconds "${OPT_SECONDS:-300}" \
    "Iteration $i. Current best score: $best. Improve the artifact, then run ./score.sh yourself to see the score." \
    > "logs/iter-$i.log" 2>&1
  new="$(score)"
  if better "$new" "$best"; then
    verdict="KEEP"; best="$new"
    git add -A && git commit -qm "iter $i: KEEP score=$new"
  else
    verdict="DROP"; git reset -q --hard HEAD
  fi
  printf "%s\t%s\t%s\t%s\n" "$i" "$new" "$best" "$verdict" | tee -a experiments.tsv
done
