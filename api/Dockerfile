# dx03v2 API image. Build context: repository root (npm workspaces, one root lockfile):
#   docker build -f api/Dockerfile --build-arg GIT_SHA="$(git rev-parse HEAD)" -t dx03v2-api:local .
# Runtime: distroless Node.js 24 (Debian 13), non-root uid 65532, no shell and no npm.
# Default command: dist/server.js; migrations: `dist/migrate.js` as the command.
# Images are pinned by digest; update procedure in docs/MAINTENANCE.md.

# node:24-alpine3.24 (verified 2026-11-09: Node 24.22.2, npm 11.19.1)
FROM node:24-alpine3.24@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8 AS deps
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
COPY api/package.json api/
COPY web/package.json web/
RUN npm ci --workspace api --include-workspace-root=false --ignore-scripts --no-audit --no-fund

FROM deps AS build
COPY api/tsconfig.json api/tsconfig.build.json api/
COPY api/src api/src
RUN npm run build --workspace api

FROM node:24-alpine3.24@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8 AS prod-deps
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
COPY api/package.json api/
COPY web/package.json web/
RUN npm ci --workspace api --include-workspace-root=false --omit=dev --ignore-scripts --no-audit --no-fund

# gcr.io/distroless/nodejs24-debian13:nonroot (verified 2026-11-09: Node 24.22.2). The debian12
# variant suggested by the spec is no longer rebuilt (still Node 24.14.0): see docs/ARCHITECTURE.md.
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:088a01637f22908632ba09018be2e0b516f2fa6f7869c191d29491139db43c78 AS runtime
ARG GIT_SHA=unknown
ARG SOURCE_REPOSITORY=maringelix/dx03v2
LABEL org.opencontainers.image.title="dx03v2-api" \
      org.opencontainers.image.description="dx03v2 message board API (Express 5, PostgreSQL 17)" \
      org.opencontainers.image.source="https://github.com/${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"
ENV NODE_ENV=production \
    GIT_SHA=${GIT_SHA}
WORKDIR /app/api
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY api/package.json ./
COPY api/migrations ./migrations
COPY --from=build /app/api/dist ./dist
USER 65532:65532
EXPOSE 3000 9464
CMD ["dist/server.js"]
