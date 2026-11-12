#!/bin/sh
# Sauvegarde chiffrée de la base (AES-256), vérifiée, conservée BACKUP_KEEP_DAYS jours,
# et copiée hors du serveur si RCLONE_REMOTE est renseigné.
#   sh /backup.sh        -> boucle quotidienne (service « backup »)
#   sh /backup.sh now    -> une sauvegarde immédiate (utilisée avant chaque déploiement)
set -eu

ensure_tools() {
  command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null
  if [ -n "${RCLONE_REMOTE:-}" ]; then command -v rclone >/dev/null 2>&1 || apk add --no-cache rclone >/dev/null; fi
}

run_backup() {
  ensure_tools
  f="/backups/multipressing-$(date +%Y-%m-%d_%H%M%S).sql.gz.enc"
  if ! pg_dump --no-owner --format=plain | gzip -9 \
      | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_PASSPHRASE -out "$f.tmp"; then
    rm -f "$f.tmp"; echo "{\"level\":\"error\",\"msg\":\"Échec de la sauvegarde\"}" >&2; return 1
  fi
  # Vérification : le fichier se déchiffre, se décompresse et contient bien la fin du dump.
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BACKUP_PASSPHRASE -in "$f.tmp" | gunzip | tail -n 5 | grep -q "PostgreSQL database dump complete"; then
    rm -f "$f.tmp"; echo "{\"level\":\"error\",\"msg\":\"Sauvegarde illisible, supprimée\"}" >&2; return 1
  fi
  mv "$f.tmp" "$f"
  echo "{\"level\":\"info\",\"msg\":\"Sauvegarde vérifiée\",\"file\":\"$f\",\"bytes\":$(wc -c < "$f")}"
  if [ -n "${RCLONE_REMOTE:-}" ]; then
    if rclone copy "$f" "$RCLONE_REMOTE" --s3-no-check-bucket; then
      echo "{\"level\":\"info\",\"msg\":\"Copie hors serveur réussie\",\"remote\":\"$RCLONE_REMOTE\"}"
    else
      echo "{\"level\":\"error\",\"msg\":\"Échec de la copie hors serveur\"}" >&2
    fi
  fi
  find /backups -name 'multipressing-*.sql.gz.enc' -mtime +"${BACKUP_KEEP_DAYS:-30}" -delete
  date +%s > /backups/.last-success
}

if [ "${1:-}" = "now" ]; then run_backup; exit $?; fi

echo "{\"level\":\"info\",\"msg\":\"Sauvegardes programmées chaque jour à ${BACKUP_HOUR:-02} h\"}"
while true; do
  if [ "$(date +%H)" = "${BACKUP_HOUR:-02}" ] && [ ! -f "/backups/.done-$(date +%Y-%m-%d)" ]; then
    if run_backup; then rm -f /backups/.done-*; touch "/backups/.done-$(date +%Y-%m-%d)"; fi
  fi
  sleep 600
done
