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
# DROP needs HEAD to reset to: on a fresh repo, commit the baseline now
# rather than discovering an unborn HEAD mid-loop.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add -A
  git commit -qm "baseline" || {
    echo "loop.sh: baseline commit failed (set git user.name/user.email)" >&2
    exit 1
  }
fi
mkdir -p logs

better() {  # better NEW BEST -> exit 0 if new improves on best
  awk -v n="$1" -v b="$2" -v d="$DIR" 'BEGIN{exit !(d=="min" ? n<b : n>b)}'
}

# stderr is the diagnostics channel: the score is stdout's last line, the
# *reason* for it goes to logs/score.err for the next iteration's prompt.
score() { ./score.sh 2>logs/score.err | tail -1; }

best="$(score)"
[ -n "$best" ] || { echo "score.sh printed no baseline score"; exit 1; }
echo "baseline score: $best" | tee experiments.tsv
echo -e "iter\tscore\tbest\tverdict\twhat" >> experiments.tsv

for i in $(seq 1 "$ITERS"); do
  git add -A && git commit -qm "iter $((i-1)) end" --allow-empty
  "$AGENT" --repo . --instructions program.md \
    --max-requests "${OPT_MAX_REQ:-15}" --max-seconds "${OPT_SECONDS:-300}" \
    "Iteration $i. Current best score: $best. Prior attempts (iter score best verdict files):
$(tail -20 experiments.tsv)
Last scorer output: $(tail -8 logs/score.err 2>/dev/null)
Improve the artifact, then run ./score.sh yourself to see the score." \
    > "logs/iter-$i.log" 2>&1
  # capture the attempt's identity before scoring: recording first keeps a
  # score.sh/program.md tamper visible in `what`, and a DROP reset would
  # erase the diff — dropped mutations are the history worth keeping
  git add -A
  what="$(git diff --cached --name-status HEAD -- . ':(exclude)logs' ':(exclude)experiments.tsv' | tr '\t' ' ' | paste -sd, -)"
  # the scorer and the rules are not artifacts: restore them before scoring
  # so an agent that edits its own oracle cannot buy a KEEP
  git checkout -q HEAD -- score.sh program.md
  new="$(score)"
  if [ -n "$new" ] && better "$new" "$best"; then
    verdict="KEEP"; best="$new"
    git commit -qm "iter $i: KEEP score=$new"
  else
    verdict="DROP"
    # reset alone leaves new untracked files behind; clean them too
    # (logs/ is exempt so this iteration's log survives the discard).
    git reset -q --hard HEAD
    git clean -fdq -e logs/
  fi
  printf "%s\t%s\t%s\t%s\t%s\n" "$i" "$new" "$best" "$verdict" "$what" | tee -a experiments.tsv
done
