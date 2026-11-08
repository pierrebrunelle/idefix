# journal-replay: a journal cut mid-batch must resume without replaying
# an unpaired tool_call (mini's assert_append_only equivalent). Goes red
# if rebuild_history ever stops dropping the dangling assistant msg.
rm -rf /tmp/idefix-jrep
run_mode jreplay ./idefix --repo . --state-dir /tmp/idefix-jrep "task" >/dev/null 2>&1

python3 - <<'PYEOF'
import glob
src = glob.glob('/tmp/idefix-jrep/sessions/*/journal.jsonl')
assert src, 'no journal written'
lines = open(src[0]).read().splitlines()
keep = []
for l in lines:
    keep.append(l)
    if '"tool_calls"' in l:
        break
assert any('"tool_calls"' in l for l in keep), 'no call in journal'
open('/tmp/idefix-jrep/trunc.jsonl', 'w').write('\n'.join(keep) + '\n')
PYEOF

run_mode jreplay ./idefix --repo . --resume /tmp/idefix-jrep/trunc.jsonl "task" >/dev/null 2>&1

python3 - <<'PYEOF' && echo "PASS journal pairing on resume" || { echo "FAIL journal pairing on resume"; FAIL=1; }
import json
bodies = [l[len('STUB body: '):] for l in open('/tmp/stub_jreplay.log')
          if l.startswith('STUB body: ')]
assert bodies, 'no requests logged'
msgs = json.loads(bodies[0])
bad = 0
for i, m in enumerate(msgs):
    if m.get('role') == 'assistant' and m.get('tool_calls'):
        need = len(m['tool_calls'])
        got = sum(1 for x in msgs[i+1:i+1+need] if x.get('role') == 'tool')
        if got < need:
            bad += 1
assert bad == 0, 'unpaired tool_call(s) in replayed history: %d' % bad
PYEOF
rm -rf /tmp/idefix-jrep
