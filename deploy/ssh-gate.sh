#!/usr/bin/env bash
# Commande forcée de la clé SSH de GitHub Actions (dans ~/.ssh/authorized_keys : command="…/ssh-gate.sh").
# Quoi que demande la connexion, seule l'une de ces commandes est exécutée :
#   deploy <tag> <utilisateur-registre>   (le jeton du registre arrive sur l'entrée standard)
#   rollback
# Ainsi, une clé de déploiement volée ne donne ni shell, ni transfert de port, ni autre commande.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/multipressing}
refuse() { echo "Refusé : $1" >&2; exit 2; }

read -r -a args <<< "${SSH_ORIGINAL_COMMAND:-}"
case "${args[0]:-}" in
  deploy)
    [ "${#args[@]}" -eq 3 ] || refuse "usage : deploy <tag> <utilisateur>"
    tag=${args[1]}; actor=${args[2]}
    [[ "$tag" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || refuse "tag invalide"
    [[ "$actor" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || refuse "utilisateur invalide"
    ;;
  rollback)
    [ "${#args[@]}" -eq 1 ] || refuse "usage : rollback"
    tag=--rollback; actor=""
    ;;
  *) refuse "seules les commandes « deploy <tag> <utilisateur> » et « rollback » sont autorisées" ;;
esac

cd "$APP_DIR"
if [ -n "$actor" ]; then
  token=$(head -c 4096)
  [ -n "$token" ] || refuse "jeton du registre manquant"
  printf '%s' "$token" | docker login ghcr.io -u "$actor" --password-stdin >/dev/null
  trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
fi
./deploy.sh "$tag"
