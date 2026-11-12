#!/usr/bin/env bash
# Teste deploy/deploy.sh sans serveur : une fausse commande « docker » simule les conteneurs.
# Scénarios : déploiement réussi, version qui ne démarre pas (retour arrière), migration en échec,
# image absente, retour arrière manuel.
# Les conditions passées à check() sont volontairement entre apostrophes : elles sont évaluées plus tard (eval).
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/app"
cp "$ROOT/deploy/deploy.sh" "$WORK/app/deploy.sh"

# Fausse commande docker : lit APP_TAG dans l'environnement ou dans .env, journalise les appels.
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
tag_env() { grep '^APP_TAG=' .env | cut -d= -f2; }
case "$*" in
  "compose pull app")                 [ "${APP_TAG}" != "absente" ] ;;
  "compose ps --status running backup") echo "backup" ;;
  "compose exec -T backup sh /backup.sh now") true ;;
  compose\ run*migrate.js)            [ "${APP_TAG}" != "migration-ko" ] ;;
  compose\ up*)                       tag_env > "$STUB_RUNNING" ;;
  compose\ exec\ -T\ app\ wget*)      r=$(cat "$STUB_RUNNING" 2>/dev/null); [ "$r" = "cassee" ] || echo "{\"status\":\"ok\",\"version\":\"$r\"}" ;;
  compose\ logs*|image\ prune*)       true ;;
  *) echo "appel inattendu : $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/docker"

export PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/calls.log" STUB_RUNNING="$WORK/running" HEALTH_TIMEOUT=2
cd "$WORK/app"
printf 'DOMAIN=test\nAPP_IMAGE=ghcr.io/test/multipressing\nAPP_TAG=v1.0.0\n' > .env
echo "2026-01-01T00:00:00Z v1.0.0" > .deploy-history
echo v1.0.0 > "$STUB_RUNNING"

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "ÉCHEC - $1"; fail=1; fi; }
tag() { grep '^APP_TAG=' .env | cut -d= -f2; }

./deploy.sh v1.1.0 >/dev/null 2>&1; rc=$?
check "déploiement réussi"                       '[ $rc -eq 0 ] && [ "$(tag)" = v1.1.0 ] && [ "$(cat "$STUB_RUNNING")" = v1.1.0 ]'
check "historique mis à jour"                    'tail -n1 .deploy-history | grep -q " v1.1.0$"'
check "sauvegarde faite avant la migration"      'grep -n "backup.sh now\|migrate.js" "$STUB_LOG" | head -2 | tail -1 | grep -q migrate'

set +e; ./deploy.sh cassee >/dev/null 2>&1; rc=$?; set -e
check "version cassée : échec signalé"            '[ $rc -ne 0 ]'
check "version cassée : retour à v1.1.0"          '[ "$(tag)" = v1.1.0 ] && [ "$(cat "$STUB_RUNNING")" = v1.1.0 ]'

set +e; ./deploy.sh migration-ko >/dev/null 2>&1; rc=$?; set -e
check "migration en échec : application intacte" '[ $rc -ne 0 ] && [ "$(tag)" = v1.1.0 ] && [ "$(cat "$STUB_RUNNING")" = v1.1.0 ]'

set +e; ./deploy.sh absente >/dev/null 2>&1; rc=$?; set -e
check "image absente : rien n'est modifié"        '[ $rc -ne 0 ] && [ "$(tag)" = v1.1.0 ]'

set +e; ./deploy.sh 'v1;rm -rf /' >/dev/null 2>&1; rc=$?; set -e
check "tag invalide refusé"                       '[ $rc -ne 0 ] && [ "$(tag)" = v1.1.0 ]'

./deploy.sh --rollback >/dev/null 2>&1; rc=$?
check "retour arrière manuel vers v1.0.0"         '[ $rc -eq 0 ] && [ "$(tag)" = v1.0.0 ] && [ "$(cat "$STUB_RUNNING")" = v1.0.0 ]'

exit $fail
