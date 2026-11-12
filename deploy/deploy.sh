#!/usr/bin/env bash
# Déploie une version de l'application sur ce serveur, avec retour arrière automatique.
#
#   ./deploy.sh <tag>        ex. ./deploy.sh v1.4.0   ou   ./deploy.sh sha-3f2a9c1
#   ./deploy.sh --rollback   revient à la version précédente
#
# Étapes : téléchargement de l'image -> sauvegarde de la base -> migrations -> remplacement
# de l'application -> contrôle de santé (version attendue) -> retour arrière si échec.
# Règle d'or : une migration doit rester compatible avec la version précédente du code
# (ajouter des colonnes ou des tables, ne pas en supprimer dans la même version).
set -Eeuo pipefail

cd "$(dirname "$0")"
ENV_FILE=.env
STATE_FILE=.deploy-history
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-90}

log() { printf '{"time":"%s","level":"%s","msg":"%s"}\n' "$(date -u +%FT%TZ)" "$1" "$2"; }
die() { log error "$1"; exit 1; }

[ -f "$ENV_FILE" ] || die "Fichier $ENV_FILE introuvable dans $(pwd)"
current_tag() { grep -E '^APP_TAG=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true; }
set_tag() {
  if grep -qE '^APP_TAG=' "$ENV_FILE"; then sed -i "s|^APP_TAG=.*|APP_TAG=$1|" "$ENV_FILE"; else echo "APP_TAG=$1" >> "$ENV_FILE"; fi
}
healthy_version() {
  docker compose exec -T app wget -qO- http://127.0.0.1:3000/healthz 2>/dev/null \
    | sed -n 's/.*"status":"ok".*"version":"\([^"]*\)".*/\1/p'
}
wait_healthy() {
  local want=$1 deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    [ "$(healthy_version)" = "$want" ] && return 0
    sleep 3
  done
  return 1
}
switch_to() {
  set_tag "$1"
  docker compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" app || true
}

if [ "${1:-}" = "--rollback" ]; then
  prev=$(tail -n 2 "$STATE_FILE" 2>/dev/null | head -n1 | cut -d' ' -f2)
  [ -n "$prev" ] || die "Aucune version précédente connue"
  TARGET=$prev
else
  TARGET=${1:-}
  [[ "$TARGET" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "Usage : ./deploy.sh <tag> | --rollback"
fi
PREVIOUS=$(current_tag)
log info "Déploiement de $TARGET (version actuelle : ${PREVIOUS:-aucune})"

# 1. Image : téléchargée avant toute modification (si le registre échoue, rien n'a changé).
APP_TAG=$TARGET docker compose pull app || die "Image $TARGET introuvable dans le registre"

# 2. Sauvegarde de la base avant les migrations.
if docker compose ps --status running backup | grep -q backup; then
  docker compose exec -T backup sh /backup.sh now || die "Sauvegarde impossible : déploiement annulé"
else
  log warn "Service de sauvegarde arrêté : pas de sauvegarde avant migration"
fi

# 3. Migrations (avec la nouvelle image, avant de remplacer l'application).
APP_TAG=$TARGET docker compose run --rm --no-deps -e APP_VERSION="$TARGET" app node src/scripts/migrate.js \
  || die "Échec des migrations : l'application en place n'a pas été modifiée"

# 4. Remplacement de l'application, puis contrôle de santé.
switch_to "$TARGET"
if wait_healthy "$TARGET"; then
  echo "$(date -u +%FT%TZ) $TARGET" >> "$STATE_FILE"
  docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
  log info "Version $TARGET en ligne et en bonne santé"
  exit 0
fi

# 5. Retour arrière automatique.
log error "La version $TARGET ne répond pas correctement : retour à ${PREVIOUS:-rien}"
docker compose logs --tail 50 app || true
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$TARGET" ]; then
  switch_to "$PREVIOUS"
  if wait_healthy "$PREVIOUS"; then log warn "Retour arrière réussi : $PREVIOUS est en ligne"; else log error "Retour arrière en échec : intervention manuelle nécessaire"; fi
fi
exit 1
