# syntax=docker/dockerfile:1.7
# ---- dépendances de production ----
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# ---- image finale ----
FROM node:22-alpine
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="multipressing" \
      org.opencontainers.image.description="Gestion d'un réseau de pressings" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"
ENV NODE_ENV=production TZ=Africa/Dakar APP_VERSION=${APP_VERSION}
# npm, npx et yarn ne servent pas à l'exécution : on les retire (surface d'attaque, alertes du scanner).
RUN apk add --no-cache tzdata tini && apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY public ./public
USER node
EXPOSE 3000 9464
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD wget -qO- http://127.0.0.1:3000/healthz || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
