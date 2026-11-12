# Runbook : que faire quand…

Toutes les commandes se lancent sur le serveur, après connexion :

```bash
ssh deploy@ADRESSE_IP_DU_VPS
```

```bash
cd /opt/multipressing
```

## L'application ne répond plus
1. Vérifiez l'état des services ; chacun doit être `running` ou `healthy` :

```bash
docker compose ps
```

2. Lisez les dernières erreurs de l'application :

```bash
docker compose logs --since 30m app | jq -c 'select(.level=="error")'
```

3. Si la base est en cause, lisez ses journaux :

```bash
docker compose logs --since 30m db
```

4. Redémarrez l'application. Cela ne touche pas aux données :

```bash
docker compose restart app
```

5. Si le problème est apparu juste après un déploiement, revenez à la version précédente (voir ci-dessous).

## Revenir à la version précédente
Depuis GitHub : onglet Actions, workflow **CD**, « Run workflow », puis choisissez l'environnement et le tag précédent.

Directement sur le serveur :

```bash
./deploy.sh --rollback
```

Pour voir les versions déployées :

```bash
cat .deploy-history
```

Une migration n'est jamais annulée automatiquement. Les migrations sont écrites pour rester compatibles avec la version précédente (voir docs/DEVOPS.md).

## Le disque est presque plein

```bash
df -h /
```

```bash
docker system df
```

Supprimez les images inutilisées depuis plus de 7 jours :

```bash
docker image prune -af --filter until=168h
```

Repérez les plus grosses sauvegardes :

```bash
du -sh backups/* | sort -h | tail
```

Si les données ont beaucoup grossi, lancez une purge depuis l'application : Administrateur, puis Archives et purge.

## Un compte est compromis ou un gérant quitte l'entreprise
Dans l'application, ouvrez Équipe et cliquez sur **Désactiver** : la personne est déconnectée immédiatement. Le journal d'audit garde ses opérations.

Si vous soupçonnez que `SESSION_SECRET` a fuité, changez-le dans le vault, rejouez Ansible, puis redémarrez l'application. Tout le monde devra se reconnecter :

```bash
docker compose up -d app
```

## Un utilisateur a perdu son téléphone (double authentification)
Dans l'application, ouvrez Équipe et cliquez sur **Réinitialiser la 2FA** pour la personne. Elle est déconnectée et reconfigurera son application à la prochaine connexion. Pour votre propre compte administrateur, utilisez la procédure ci-dessous.

## La clé de déploiement GitHub a pu fuiter
1. Créez une nouvelle clé (voir docs/DEVOPS.md, section b).
2. Remplacez l'ancienne dans `deploy_ci_keys`, puis rejouez Ansible.
3. Mettez à jour le secret `DEPLOY_SSH_KEY` dans GitHub.

Même volée, l'ancienne clé ne pouvait que déployer une image publiée.

## Mot de passe ou double authentification de l'administrateur perdus
Cette commande réinitialise le mot de passe **et** la double authentification du compte :

```bash
docker compose exec app node src/scripts/create-admin.js --email vous@exemple.com
```

## Paiement en ligne : le client a payé mais le ticket ne l'indique pas
1. Ouvrez le ticket : le suivi interroge Wave toutes les 3 secondes et le rattrapage tourne toutes les 3 minutes. Attendez quelques minutes.
2. Cherchez une alerte « Paiement en ligne incohérent » dans le journal d'audit. Elle signale que le montant ou la référence diffèrent chez Wave : vérifiez dans votre espace Wave Business.
3. Vérifiez les identifiants du compte concerné dans « Règles de la boutique » : pour Wave, le webhook déclaré et son secret ; pour PayDunya, l'environnement (Sandbox ou Production) et les trois identifiants. Une notification refusée apparaît dans les journaux :

```bash
docker compose logs --since 1h app | grep -i notification
```

4. En dernier recours, après avoir vérifié le paiement dans l'espace du fournisseur (Wave Business ou PayDunya), annulez le lien en attente puis encaissez manuellement. Si le lien annulé est quand même payé ensuite, l'application l'enregistre et le signale « PAYÉ APRÈS ANNULATION » : annulez alors l'encaissement manuel en double.

## Un trop-perçu est signalé
Le journal indique « TROP-PERÇU de X FCFA à rembourser » : le client a payé en ligne alors que le solde était déjà réglé. Remboursez-le depuis l'espace du fournisseur (Wave Business ou PayDunya), puis annulez l'encaissement correspondant dans le ticket (administrateur, avec un motif).

## Restaurer une sauvegarde
**Attention : cela remplace toutes les données actuelles.** Faites d'abord une sauvegarde de l'état actuel :

```bash
docker compose exec backup sh /backup.sh now
```

Arrêtez l'application :

```bash
docker compose stop app
```

Déchiffrez la sauvegarde choisie (la phrase est `BACKUP_PASSPHRASE`, conservée hors du serveur) :

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in backups/FICHIER.sql.gz.enc | gunzip > /tmp/restauration.sql
```

Recréez une base vide :

```bash
docker compose exec -T db sh -c 'dropdb -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
```

Chargez la sauvegarde :

```bash
docker compose exec -T db sh -c 'psql -q -U "$POSTGRES_USER" "$POSTGRES_DB"' < /tmp/restauration.sql
```

Redémarrez l'application et supprimez le fichier temporaire :

```bash
docker compose start app && rm /tmp/restauration.sql
```

**Restauration d'essai sans toucher à la production** (à faire chaque trimestre) : démarrez une base temporaire, chargez-y la sauvegarde déchiffrée, comptez les tickets, puis supprimez la base temporaire.

```bash
docker run -d --name restore-test -e POSTGRES_PASSWORD=test postgres:16-alpine
```

```bash
sleep 5 && docker exec -i restore-test psql -q -U postgres < /tmp/restauration.sql
```

```bash
docker exec restore-test psql -U postgres -c "select count(*) from tickets"
```

```bash
docker rm -f restore-test && rm /tmp/restauration.sql
```

## Le certificat HTTPS ne se renouvelle pas
Caddy renouvelle seul ses certificats. Vérifiez que le DNS pointe toujours vers le serveur et que les ports 80 et 443 sont ouverts, puis lisez ses journaux :

```bash
docker compose logs --since 24h caddy | grep -i -E "error|acme"
```
