#!/usr/bin/env bash
# acp migrate answer records the owner's answer to one question of the plan, and only then: the plan's two files must
# carry the same plan id, the answer must be one of the question's options (or, where the plan asks for a folder, an
# absolute folder outside the project), and nothing but that answer in moves.json changes; the plan's two files must be
# the plan written for this project, and two runs at once refuse rather than lose an answer.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
run() { perl -e 'alarm 60; exec @ARGV' "$ACP" migrate "$@"; }
P="$EVAL_TMP/proj"; R="$P/eng"; D="$P/.acp-migration"; J="$D/moves.json"; MD="$D/MIGRATION-PLAN.md"
mkdir -p "$R/src" "$P/profiles" && G -C "$R" init -q && printf 'export WORKORDERS_DIR="Workspace/Docs/WorkOrders"\n' > "$R/pipeline.config.sh" \
  && printf 'x\n' > "$R/src/a.py" && printf 'h\n' > "$R/HANDOFF-2026-01-01.md" && G -C "$R" add -A && G -C "$R" commit -qm base \
  && printf 'p: 1\n' > "$P/profiles/client.setup.yaml" || { echo "FAIL setup: project"; exit 1; }
(cd "$P" && run plan >/dev/null 2>&1) || { echo "FAIL setup: plan"; exit 1; }
pid() { "$PY" -c 'import json, sys; print(json.load(open(sys.argv[1])).get("plan_id", ""))' "$J"; }
recompute() { "$PY" -c 'import hashlib, json, sys; d = json.load(open(sys.argv[1])); d.pop("plan_id", None); d.pop("plan_md_sha256", None); d["questions"] = [dict(q, answer=None) for q in d["questions"]]; print(hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest())' "$J"; }
qn() { "$PY" -c 'import json, sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if sys.argv[2] in q["question"]][0])' "$J" "$1"; }
# A1: the plan carries one plan id, in both files, and it is the sha256 of the plan with its answers left out
id="$(pid)"
mdsha="$("$PY" -c 'import json, sys; print(json.load(open(sys.argv[1])).get("plan_md_sha256", ""))' "$J")"
{ [ ${#id} -eq 64 ] && [ "$id" = "$(recompute)" ] && [ "$(grep -c '^- Plan id: ' "$MD")" -eq 1 ] && grep -qF -- "- Plan id: \`$id\`" "$MD" \
  && [ "$mdsha" = "$(shasum -a 256 "$MD" | cut -d' ' -f1)" ]; } || { echo "FAIL A1: the plan does not carry one plan id in both files"; exit 1; }
# A2: an answer that is one of the options is recorded; nothing else in moves.json changes, and the id still holds
QL="$(qn "is a loose work document")"; QF="$(qn "private items")"
QO="$("$PY" -c 'import json, sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q["n"] not in (int(sys.argv[2]), int(sys.argv[3]))][0])' "$J" "$QL" "$QF")"
OO="$("$PY" -c 'import json, sys; print([q["options"][-1] for q in json.load(open(sys.argv[1]))["questions"] if q["n"] == int(sys.argv[2])][0])' "$J" "$QO")"
(cd "$P" && run answer "$QO" "$OO" >/dev/null 2>&1) || { echo "FAIL A2: question $QO could not be answered '$OO'"; exit 1; }
answers() { "$PY" -c 'import json, sys; print(json.dumps({q["n"]: q["answer"] for q in json.load(open(sys.argv[1]))["questions"] if q["n"] != int(sys.argv[2])}, sort_keys=True))' "$J" "$1"; }
others="$(answers "$QL")"; mdsum="$(shasum -a 256 "$MD" | cut -d' ' -f1)"; list0="$(ls -A "$D")"
before="$("$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); [q.update(answer=None) for q in d["questions"]]; print(json.dumps(d, sort_keys=True))' "$J")"
out="$(cd "$P" && run answer "$QL" delete 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "acp migrate answer: question $QL: delete (was unanswered)." <<< "$out"; } || { echo "FAIL A2: a valid answer was not recorded (exit $rc): $out"; exit 1; }
[ "$("$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); print([q["answer"] for q in d["questions"] if q["n"] == int(sys.argv[2])][0])' "$J" "$QL")" = delete ] || { echo "FAIL A2: moves.json does not hold the answer"; exit 1; }
{ [ "$(answers "$QL")" = "$others" ] && [ "$(shasum -a 256 "$MD" | cut -d' ' -f1)" = "$mdsum" ] && [ "$(ls -A "$D")" = "$list0" ]; } \
  || { echo "FAIL A2: answering changed another answer, MIGRATION-PLAN.md, or what .acp-migration holds"; exit 1; }
after="$("$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); [q.update(answer=None) for q in d["questions"]]; print(json.dumps(d, sort_keys=True))' "$J")"
{ [ "$before" = "$after" ] && [ "$(pid)" = "$id" ] && [ "$(recompute)" = "$id" ]; } || { echo "FAIL A2: answering changed more than the answer, or broke the plan id"; exit 1; }
out="$(cd "$P" && run answer "$QL" yes 2>&1)"; grep -qF "question $QL: yes (was delete)." <<< "$out" || { echo "FAIL A2: a changed answer does not say what it was: $out"; exit 1; }
# A3: an option the question does not have, a question that does not exist, and bad usage refuse, changing nothing
snap() { shasum -a 256 "$J" "$MD" 2>/dev/null | cut -d' ' -f1 | tr '\n' ' '; ls -A "$D" 2>/dev/null | tr '\n' ' '; }   # a missing file is part of the state
refused() { # <case> <expected line> <args...>
  local c="$1" want="$2"; shift 2; local s0; s0="$(snap)"; out="$(cd "$P" && run answer "$@" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qxF -- "$want" <<< "$out" && [ "$(snap)" = "$s0" ]; } || { echo "FAIL $c: expected exit 1 and '$want', nothing changed (exit $rc): $out"; exit 1; }; }
refused A3 "acp migrate answer: question $QL has no option 'maybe'; its options: yes, delete, keep where it is" "$QL" maybe
refused A3 "acp migrate answer: question $QL has no option 'DELETE'; its options: yes, delete, keep where it is" "$QL" DELETE
refused A3 "acp migrate answer: question $QL has no option 'a\x0ab'; its options: yes, delete, keep where it is" "$QL" "$(printf 'a\nb')"
NQ="$("$PY" -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["questions"]))' "$J")"
refused A3 "acp migrate answer: there is no question 999 (questions 1 to $NQ)" 999 yes
refused A3 "acp migrate answer: there is no question x1 (questions 1 to $NQ)" x1 yes
refused A3 "acp migrate answer: usage: acp migrate answer <n> <option>  |  acp migrate answer <n> --folder <absolute folder>" "$QL"
# A4: the question that asks for a folder takes only --folder with an absolute folder outside the project
RP="$(cd "$P" && pwd -P)"
refused A4 "acp migrate answer: question $QF asks for a folder: acp migrate answer $QF --folder <absolute folder outside the project>" "$QF" yes
refused A4 "acp migrate answer: question $QF needs an absolute folder, on one line" "$QF" --folder relative/folder
refused A4 "acp migrate answer: $RP/inside is inside the project; question $QF asks for a folder outside it" "$QF" --folder "$RP/inside"
mkdir -p "$EVAL_TMP/x" && ln -s "$RP" "$EVAL_TMP/plink" || { echo "FAIL setup: a link into the project"; exit 1; }
refused A4 "acp migrate answer: $EVAL_TMP/plink/inside is inside the project; question $QF asks for a folder outside it" "$QF" --folder "$EVAL_TMP/plink/inside"
refused A4 "acp migrate answer: $EVAL_TMP/x/../proj/inside is inside the project; question $QF asks for a folder outside it" "$QF" --folder "$EVAL_TMP/x/../proj/inside"
UP="$(tr '[:lower:]' '[:upper:]' <<< "$RP")"   # the same folder only where names ignore case (macOS); elsewhere it is another path
if [ -d "$UP" ]; then refused A4 "acp migrate answer: $UP/inside is inside the project; question $QF asks for a folder outside it" "$QF" --folder "$UP/inside"; fi
refused A4 "acp migrate answer: question $QL is answered with one of its options: yes, delete, keep where it is" "$QL" --folder "$EVAL_TMP/private"
out="$(cd "$P" && run answer "$QF" --folder "$EVAL_TMP/private" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "question $QF: $EVAL_TMP/private (was unanswered)." <<< "$out"; } || { echo "FAIL A4: a folder outside the project was not recorded (exit $rc): $out"; exit 1; }
# A5: plan files that are not the same plan refuse: moves.json edited by hand, or MIGRATION-PLAN.md from another run
cp "$J" "$EVAL_TMP/moves.keep"; cp "$MD" "$EVAL_TMP/plan.keep"
"$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); d["entries"][0]["to"] = "elsewhere/"; json.dump(d, open(sys.argv[1], "w"))' "$J"
refused A5 "acp migrate answer: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace" "$QL" yes
cp "$EVAL_TMP/moves.keep" "$J"; sed 's/^- Plan id: `[0-9a-f]*`/- Plan id: `0000000000000000000000000000000000000000000000000000000000000000`/' "$EVAL_TMP/plan.keep" > "$MD"
refused A5 "acp migrate answer: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace" "$QL" yes
cp "$EVAL_TMP/plan.keep" "$MD"; perl -pi -e 's/is a loose work document/is a work document/' "$MD"   # a question row edited
refused A5 "acp migrate answer: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace" "$QL" yes
cp "$EVAL_TMP/plan.keep" "$MD"; grep '^- Plan id: ' "$EVAL_TMP/plan.keep" >> "$MD"   # a second id line
refused A5 "acp migrate answer: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace" "$QL" yes
# both files edited to agree: a second id line, and moves.json's hash of MIGRATION-PLAN.md set to match it
"$PY" -c 'import hashlib, json, sys; d = json.load(open(sys.argv[1])); d["plan_md_sha256"] = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest(); json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)' "$J" "$MD"
refused A5 "acp migrate answer: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace" "$QL" yes
cp "$EVAL_TMP/moves.keep" "$J"
cp "$EVAL_TMP/plan.keep" "$MD"
cp -R "$P" "$EVAL_TMP/copy" || { echo "FAIL setup: copy"; exit 1; }   # a copy of the project: its plan was made for the original
c0="$(shasum -a 256 "$EVAL_TMP/copy/.acp-migration/moves.json")"; out="$(cd "$EVAL_TMP/copy" && run answer "$QL" yes 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate answer: this is not the plan's project (it was made in $RP); run: acp migrate plan --replace" <<< "$out" && [ "$(shasum -a 256 "$EVAL_TMP/copy/.acp-migration/moves.json")" = "$c0" ]; } || { echo "FAIL A5: a copy of the project was not refused as not the plan's project, or was changed (exit $rc): $out"; exit 1; }
printf '[]\n' > "$J"; refused A5 "acp migrate answer: moves.json cannot be read (it is not a plan)" "$QL" yes
cp "$EVAL_TMP/moves.keep" "$J"
# A7: two runs at once: while another holds .acp-migration's lock, answer and plan refuse and change nothing
"$PY" -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' "$D" "$EVAL_TMP/held" & HOLD=$!
i=0; while [ ! -e "$EVAL_TMP/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
refused A7 "acp migrate answer: another acp migrate is working in $RP/.acp-migration; wait for it to finish, then run this again" "$QL" yes
s0="$(snap)"; out="$(cd "$P" && run plan --replace 2>&1)"; rc=$?
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate plan: another acp migrate is working in $RP/.acp-migration; wait for it to finish, then run this again" <<< "$out" && [ "$(snap)" = "$s0" ]; } \
  || { echo "FAIL A7: plan ran while another held the lock (exit $rc): $out"; exit 1; }
# A6: a linked moves.json is never written through; no plan at all refuses
mv "$J" "$EVAL_TMP/moves.real" && ln -s "$EVAL_TMP/moves.real" "$J"
refused A6 "acp migrate answer: $RP/.acp-migration/moves.json is a link or not a regular file; remove it first" "$QL" yes
rm -f "$J"; refused A6 "acp migrate answer: no plan to answer in $RP/.acp-migration (run: acp migrate plan)" "$QL" yes
mkdir "$J"; refused A6 "acp migrate answer: $RP/.acp-migration/moves.json is a link or not a regular file; remove it first" "$QL" yes; rmdir "$J"
cp "$EVAL_TMP/moves.real" "$EVAL_TMP/elsewhere-moves.json"; mkdir -p "$EVAL_TMP/elsewhere" && cp "$EVAL_TMP/moves.real" "$EVAL_TMP/elsewhere/moves.json" && cp "$MD" "$EVAL_TMP/elsewhere/" \
  && rm -rf "${D:?}" && ln -s "$EVAL_TMP/elsewhere" "$D" || { echo "FAIL setup: linked folder"; exit 1; }
out="$(cd "$P" && run answer "$QL" yes 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate answer: $RP/.acp-migration is a link or not a folder; remove it first" <<< "$out" && cmp -s "$EVAL_TMP/moves.real" "$EVAL_TMP/elsewhere/moves.json"; } || { echo "FAIL A6: a linked .acp-migration was written through, or not refused (exit $rc): $out"; exit 1; }
# A8: a folder answer that holds the project (the filesystem's root, the project's parent) or is not plain text is
# refused; a plan with no questions says so
rm -f "$D" && mkdir -p "$D" && cp "$EVAL_TMP/moves.keep" "$J" && cp "$EVAL_TMP/plan.keep" "$MD" || { echo "FAIL setup: A8"; exit 1; }
refused A8 "acp migrate answer: / holds the project; question $QF asks for a folder outside it" "$QF" --folder /
refused A8 "acp migrate answer: $(dirname "$RP") holds the project; question $QF asks for a folder outside it" "$QF" --folder "$(dirname "$RP")"
refused A8 "acp migrate answer: question $QF needs an absolute folder, on one line" "$QF" --folder "$EVAL_TMP/a$(printf '\t')b"
E="$EVAL_TMP/empty"; mkdir -p "$E/eng" && G -C "$E/eng" init -q && : > "$E/eng/pipeline.config.sh" && G -C "$E/eng" add -A && G -C "$E/eng" commit -qm b && (cd "$E/eng" && run plan >/dev/null 2>&1) || { echo "FAIL setup: empty plan"; exit 1; }
"$PY" -c 'import json, sys; sys.exit(0 if not json.load(open(sys.argv[1]))["questions"] else 1)' "$E/eng/.acp-migration/moves.json" || { echo "FAIL setup: the empty plan has questions"; exit 1; }
out="$(cd "$E/eng" && run answer 1 yes 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate answer: the plan has no questions to answer" <<< "$out"; } || { echo "FAIL A8: a plan with no questions did not say so (exit $rc): $out"; exit 1; }
exit 0
