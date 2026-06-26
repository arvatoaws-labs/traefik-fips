# =============================================================================
# Stage 1: WebUI mit Node.js/Yarn bauen
# =============================================================================
ARG TRAEFIK_VERSION=v3.7.5

FROM node:20-bullseye-slim AS webui-builder

ARG TRAEFIK_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth=1 --branch=${TRAEFIK_VERSION} \
    https://github.com/traefik/traefik.git .

WORKDIR /src/webui

RUN corepack enable && yarn install --frozen-lockfile
RUN corepack enable && yarn build

# =============================================================================
# Stage 2: Traefik mit GOFIPS140=latest kompilieren (Go 1.25+)
# =============================================================================
FROM golang:bookworm AS builder

ARG TRAEFIK_VERSION

ENV CGO_ENABLED=1
ENV GOOS=linux
ENV GOFIPS140=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libc6-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN go version && go env GOFIPS140

WORKDIR /build

RUN git clone --depth=1 --branch=${TRAEFIK_VERSION} \
    https://github.com/traefik/traefik.git .

COPY --from=webui-builder /src/webui/static ./webui/static

RUN go mod download

# Ohne -s damit die Symboltabelle erhalten bleibt (für Verifikation)
# -w unterdrückt nur DWARF-Debug-Info, das Binary bleibt klein genug
RUN BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) && \
    go build \
      -trimpath \
      -ldflags="-w \
        -X github.com/traefik/traefik/v3/pkg/version.Version=${TRAEFIK_VERSION} \
        -X github.com/traefik/traefik/v3/pkg/version.Codename=fips-custom \
        -X github.com/traefik/traefik/v3/pkg/version.BuildDate=${BUILD_DATE}" \
      -o /traefik \
      ./cmd/traefik/

# Verifikation über go tool nm (funktioniert jetzt ohne -s)
RUN echo "=== FIPS Verification ===" \
    && go env GOFIPS140 \
    && go tool nm /traefik | grep -c "fips\|boring\|FIPS" | xargs echo "FIPS-relevante Symbole:"

# =============================================================================
# Stage 3: Minimales Laufzeit-Image
# =============================================================================
FROM gcr.io/distroless/base-debian12:nonroot AS runtime

COPY --from=builder /traefik /traefik

VOLUME ["/etc/traefik"]
EXPOSE 80 443 8080
ENTRYPOINT ["/traefik"]