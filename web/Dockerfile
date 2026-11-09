# dx03v2 web image. Build context: repository root (npm workspaces, one root lockfile):
#   docker build -f web/Dockerfile --build-arg GIT_SHA="$(git rev-parse HEAD)" -t dx03v2-web:local .
# Runtime: nginx-unprivileged (uid 101) on port 8080, our own server config, read-only root
# filesystem friendly (writes only to /tmp). Images are pinned by digest (docs/MAINTENANCE.md).

# node:24-alpine3.24 (verified 2026-11-09: Node 24.22.2, npm 11.19.1)
FROM node:24-alpine3.24@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8 AS build
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
COPY api/package.json api/
COPY web/package.json web/
RUN npm ci --workspace web --include-workspace-root=false --ignore-scripts --no-audit --no-fund
COPY web/index.html web/vite.config.ts web/tsconfig.json web/
COPY web/src web/src
RUN npm run build --workspace web

# nginxinc/nginx-unprivileged:1.30-alpine-slim = 1.30.6-alpine3.24-slim, current stable line (verified
# 2026-11-09, upstream build of 2026-10-19). The slim variant ships nginx without the
# image-filter/xslt/geoip/njs modules and their libraries (libgd, libtiff, libxslt), which this config
# does not use: the regular 1.30-alpine image failed the trivy gate with a fixable HIGH in libtiff
# (CVE-2026-4775).
FROM nginxinc/nginx-unprivileged:1.30-alpine-slim@sha256:5d8bb9437d74a600ec5dbf90c035451c724dc33eac8d3a71078f6f8612c345f6 AS runtime
ARG GIT_SHA=unknown
ARG SOURCE_REPOSITORY=maringelix/dx03v2
LABEL org.opencontainers.image.title="dx03v2-web" \
      org.opencontainers.image.description="dx03v2 message board single page served by nginx-unprivileged" \
      org.opencontainers.image.source="https://github.com/${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"
ENV NGINX_ENTRYPOINT_QUIET_LOGS=1
# Temporary (2026-11-09): the newest 1.30-alpine-slim build still ships musl 1.2.6-r2 and zlib 1.3.2-r0
# (HIGH CVE-2026-107891 and CVE-2026-85091), fixed in the Alpine 3.24 repository. Install the fixed
# packages until a newer upstream digest contains them, then delete these two lines
# (docs/MAINTENANCE.md, section 5.6). The final USER below stays 101:101.
USER 0:0
RUN apk add --no-cache musl=1.2.6-r3 musl-utils=1.2.6-r3 zlib=1.4-r0
COPY web/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY web/nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=build /app/web/dist /usr/share/nginx/html
USER 101:101
EXPOSE 8080
