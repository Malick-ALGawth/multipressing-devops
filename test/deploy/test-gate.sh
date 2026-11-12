#!/usr/bin/env bash
# Teste deploy/ssh-gate.sh : seules les commandes de déploiement autorisées passent.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/app"
printf '#!/bin/sh\necho "docker $*" >> "%s/calls"\ncat >/dev/null\n' "$WORK" > "$WORK/bin/docker"
printf '#!/bin/sh\necho "deploy.sh $*" >> "%s/calls"\n' "$WORK" > "$WORK/app/deploy.sh"
chmod +x "$WORK/bin/docker" "$WORK/app/deploy.sh"
export PATH="$WORK/bin:$PATH" APP_DIR="$WORK/app"

fail=0
run() { : > "$WORK/calls"; SSH_ORIGINAL_COMMAND="$1" bash "$ROOT/deploy/ssh-gate.sh" <<< "${2:-}" >/dev/null 2>&1; }
check() { if eval "$2"; then echo "ok   - $1"; else echo "ÉCHEC - $1"; fail=1; fi; }

set +e
run "deploy v1.2.0 malick-algawth" "jeton";  rc=$?; check "déploiement autorisé"     '[ $rc -eq 0 ] && grep -q "deploy.sh v1.2.0" "$WORK/calls" && grep -q "docker login" "$WORK/calls" && grep -q "docker logout" "$WORK/calls"'
run "rollback";                               rc=$?; check "retour arrière autorisé"  '[ $rc -eq 0 ] && grep -q "deploy.sh --rollback" "$WORK/calls"'
set +e
run "bash";                                   rc=$?; check "shell refusé"                 '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
run "deploy v1;id malick" "j";                rc=$?; check "injection dans le tag refusée" '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
run 'deploy $(id) malick' "j";                rc=$?; check "substitution refusée"         '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
run "deploy v1.2.0 malick extra" "j";         rc=$?; check "argument en trop refusé"      '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
run "deploy v1.2.0 malick" "";                rc=$?; check "jeton manquant refusé"        '[ $rc -eq 2 ] && ! grep -q deploy.sh "$WORK/calls"'
run "cat /opt/multipressing/.env";            rc=$?; check "lecture de fichier refusée"   '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
run "";                                       rc=$?; check "connexion interactive refusée" '[ $rc -eq 2 ] && [ ! -s "$WORK/calls" ]'
set -e
exit $fail
