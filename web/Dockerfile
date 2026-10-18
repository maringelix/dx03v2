# dx03v2 web image. Build context: repository root (npm workspaces, one root lockfile):
#   docker build -f web/Dockerfile --build-arg GIT_SHA="$(git rev-parse HEAD)" -t dx03v2-web:local .
# Runtime: nginx-unprivileged (uid 101) on port 8080, our own server config, read-only root
# filesystem friendly (writes only to /tmp). Images are pinned by digest (docs/MAINTENANCE.md).

# node:24-alpine3.24 (verified 2026-10-10: Node 24.21.0, npm 11.19.0)
FROM node:24-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS build
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
COPY api/package.json api/
COPY web/package.json web/
RUN npm ci --workspace web --include-workspace-root=false --ignore-scripts --no-audit --no-fund
COPY web/index.html web/vite.config.ts web/tsconfig.json web/
COPY web/src web/src
RUN npm run build --workspace web

# nginxinc/nginx-unprivileged:1.30-alpine-slim = 1.30.5-alpine3.24-slim, current stable line (verified
# 2026-10-10). The slim variant ships nginx without the image-filter/xslt/geoip/njs modules and their
# libraries (libgd, libtiff, libxslt), which this config does not use: the regular 1.30-alpine image
# failed the trivy gate with a fixable HIGH in libtiff (CVE-2026-4775).
FROM nginxinc/nginx-unprivileged:1.30-alpine-slim@sha256:3af0c10d960cc2502427fe1219c52989d309e7d65596869c60a34fd2fa2406f0 AS runtime
ARG GIT_SHA=unknown
ARG SOURCE_REPOSITORY=maringelix/dx03v2
LABEL org.opencontainers.image.title="dx03v2-web" \
      org.opencontainers.image.description="dx03v2 message board single page served by nginx-unprivileged" \
      org.opencontainers.image.source="https://github.com/${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"
ENV NGINX_ENTRYPOINT_QUIET_LOGS=1
COPY web/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY web/nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=build /app/web/dist /usr/share/nginx/html
USER 101:101
EXPOSE 8080
