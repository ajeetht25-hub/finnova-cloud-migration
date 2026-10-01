# syntax=docker/dockerfile:1.7

# ---------- Stage 1: dependencies (cached layer, no source yet) ----------
FROM node:20.17-alpine3.20 AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
# --omit=dev: production deps only; --ignore-scripts: no arbitrary install scripts
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ---------- Stage 2: build / verify ----------
FROM node:20.17-alpine3.20 AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY test ./test
# Fail the build if syntax or unit tests fail
RUN npm run lint && npm test

# ---------- Stage 3: runtime (distroless, non-root, no shell) ----------
FROM gcr.io/distroless/nodejs20-debian12:nonroot AS runtime
WORKDIR /app

# Only what is needed to run: prod deps + source. No tests, no dev tooling, no secrets.
COPY --from=deps  --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --from=build --chown=nonroot:nonroot /app/src ./src
COPY --chown=nonroot:nonroot package.json ./

ENV NODE_ENV=production \
    PORT=8080

# distroless "nonroot" = uid/gid 65532; set explicitly so Kubernetes runAsNonRoot can verify it
USER 65532:65532

EXPOSE 8080

# No HEALTHCHECK: probing is done by Kubernetes (liveness/readiness) since distroless has no curl/shell.
CMD ["src/server.js"]
