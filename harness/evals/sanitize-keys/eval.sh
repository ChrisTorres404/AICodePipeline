#!/usr/bin/env bash
# bin/sanitize finds the keys in common use (OpenAI, Anthropic, Slack, Google, GitLab, Stripe restricted keys
# and webhook secrets, AWS temporary keys, encrypted and PGP private keys, an env-file NAME_PASSWORD=value),
# leaves each one's look-alike alone, never fails on its own source, and stays fast on a long line with no spaces.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
S="$PIPELINE_ROOT/bin/sanitize"
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
# every value is built at run time from pieces, so this file holds no key, address or key block
rep() { printf "%${2}s" "" | tr ' ' "$1"; }
b='-----BEGIN'; e='-----'
n=0
scan() { rc=0; out="$("$S" "$1" 2>&1)" || rc=$?; }
has() { case "$out" in *"**[$1]** \`notes.md:1\`"*) return 0;; esac; return 1; }
# hit <check> <id> <what> <line>: the line is one critical finding of that id
hit() { n=$((n + 1)); mkdir -p "y$n" && printf '%s\n' "$4" > "y$n/notes.md"; scan "y$n"
  { [ "$rc" -eq 2 ] && has "$2"; } || die "FAIL $1: sanitize did not find $3" "exit $rc" "$out"; }
# miss <check> <what> <line>: the line is no finding at all
miss() { n=$((n + 1)); mkdir -p "n$n" && printf '%s\n' "$3" > "n$n/notes.md"; scan "n$n"
  [ "$rc" -eq 0 ] || die "FAIL $1: sanitize reported $2" "exit $rc" "$out"; }

# K1-K10: each key shape is a critical finding; N1-N10: its look-alike is not
hit K1 secret.openai "an OpenAI project key" "OPENAI_API_KEY in use: sk-""proj-$(rep A 24)$(rep 7 24)_x"
hit K1 secret.openai "an OpenAI service-account key" "key sk-""svcacct-$(rep A 30)"
hit K1 secret.openai "an OpenAI admin key" "key sk-""admin-$(rep A 30)"
hit K1 secret.openai "a legacy OpenAI key" "key sk-$(rep a 20)T3Blbk""FJ$(rep b 20)"
miss N1 "the placeholder OpenAI key the docs use" 'const apiKey = "sk-''proj-xxxxx"'
miss N1 "a legacy-shaped OpenAI key one character short" "key sk-$(rep a 20)T3Blbk""FJ$(rep b 19)"
hit K2 secret.anthropic "an Anthropic key" "key sk-""ant-api03-$(rep B 40)$(rep 9 40)"
miss N2 "a short sk-ant- string" "the prefix is sk-""ant-api03- and then the key"
hit K3 secret.slacktok "a Slack bot token" "token xox""b-$(rep 1 12)-$(rep 2 13)-$(rep c 24)"
hit K3 secret.slacktok "a Slack app token" "token xa""pp-1-A$(rep B 10)-$(rep 3 13)-$(rep f 64)"
miss N3 "a Slack token placeholder" "SLACK_BOT_TOKEN set to xox""b-your-bot-token"
miss N3 "a Slack app token placeholder" "SLACK_APP_TOKEN set to xa""pp-your-app-token"
hit K4 secret.googlekey "a Google API key" "maps key AI""za$(rep D 20)$(rep 3 15)"
miss N4 "a Google-shaped string one character too long" "maps key AI""za$(rep D 20)$(rep 3 16)"
hit K5 secret.gitlab "a GitLab token" "token glp""at-$(rep E 10)$(rep 4 10)"
hit K5 secret.gitlab "a GitLab deploy token" "token gl""dt-$(rep E 10)$(rep 4 10)"
miss N5 "a short glpat- string" "token glp""at-xxxx"
hit K6 secret.awstemp "an AWS temporary access key id" "id AS""IA$(rep Q 8)$(rep 5 8)"
miss N6 "an ASIA string one character too long" "id AS""IA$(rep Q 8)$(rep 5 9)"
hit K7 secret.privkey "an encrypted private key" "$b ENCRYPTED PRIVATE KEY$e"
miss N7 "a public key header" "$b PUBLIC KEY$e"
hit K8 secret.pgp "a PGP private key block" "$b PGP PRIVATE KEY BLOCK$e"
miss N8 "a PGP public key block" "$b PGP PUBLIC KEY BLOCK$e"
hit K9 secret.password "an unquoted password in an env file" "DB_PASS""WORD=Kp4v$(rep r 4)Xw9"
miss N9 "a password taken from a variable" "DB_PASS""WORD=\${DB_PASS""WORD}"
miss N9 "a placeholder password" "DB_PASS""WORD=secure_pass""word"
miss N9 "an empty password" "DB_PASS""WORD="
miss N9 "a password read in code" "password = request.form.get(name)"
miss N9 "a password read in lower-case code" "password=request.form.get(name)"
miss N9 "a password assigned in code" "DB_PASS""WORD = os.environ.get(name)"
hit K9 secret.password "an exported password" "export PGPASS""WORD=Kp4v$(rep r 4)Xw9"
hit K9 secret.password "a quoted password, as before" "password: \"Kp4v$(rep r 4)Xw9\""
hit K9 secret.password "a quoted env password" "POSTGRES_PASS""WORD=\"Kp4v$(rep r 4)Xw9\""
hit K9 secret.password "a password in a compose list" "      - POSTGRES_PASS""WORD=Kp4v$(rep r 4)Xw9"
miss N9 "a redacted password" "DB_PASS""WORD=[REDACTED]"
miss N9 "a masked password" "DB_PASS""WORD=$(rep '*' 8)"
miss N9 "a password made by a command" 'DB_PASS''WORD=`openssl rand -hex 16`'
miss N9 "a password from a format string" "DB_PASS""WORD=%(db_pw)s"
miss N9 "an escaped variable" 'DB_PASS''WORD=\$escaped_value'
miss N9 "a change-me password" "DB_PASS""WORD=CHANGE_ME_IN_PROD"
hit K11 secret.sk "a Stripe restricted key" "key r""k_live_$(rep K 24)"
miss N11 "a short Stripe-shaped key" "key r""k_live_xxxx"
hit K12 secret.stripewh "a Stripe webhook secret" "secret wh""sec_$(rep W 16)$(rep 8 16)"
miss N12 "a short webhook-secret-shaped string" "secret wh""sec_xxxx"
hit K10 pii.email "a personal email address, as before" "mail john.doe""@gma""il.com"
miss N10 "an example address" "mail john.doe@example.com"

# S1: sanitize run over its own source, as an installed copy or the plugin carries it, finds no critical
mkdir -p self/bin && cp "$S" self/bin/sanitize && scan self
[ "$rc" -le 1 ] || die "FAIL S1: sanitize reported its own source as critical" "exit $rc" "$out"

# T1, T2: a long line with no spaces is scanned in about the time a short one is
for t in "T1 x" "T2 a."; do
  id="${t%% *}"; unit="${t#* }"; mkdir -p "$id"
  python3 -c 'import sys; print(sys.argv[1] * (80000 // len(sys.argv[1])))' "$unit" > "$id/notes.md"
  start=$SECONDS; scan "$id"; took=$((SECONDS - start))
  [ "$took" -le 3 ] || die "FAIL $id: sanitize took ${took}s on one 80,000-character line of '$unit'"
done
echo "sanitize-keys: all checks passed"
exit 0
