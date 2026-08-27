# =============================================================================
# Stage 1: WebUI mit Node.js/Yarn bauen
# =============================================================================
FROM node:24-alpine AS webui-builder

ARG TRAEFIK_VERSION

RUN apk add --no-cache git ca-certificates

WORKDIR /src

RUN git clone --depth=1 --branch=${TRAEFIK_VERSION} \
    https://github.com/traefik/traefik.git .

WORKDIR /src/webui

RUN npm i -g @aikidosec/safe-chain
RUN safe-chain setup-ci

RUN corepack enable
RUN yarn install --frozen-lockfile
RUN yarn build

# =============================================================================
# Stage 2: Traefik mit GOFIPS140=latest kompilieren (Go 1.25+)
# =============================================================================
FROM golang:alpine AS builder

ARG TRAEFIK_VERSION

ENV CGO_ENABLED=1
ENV GOOS=linux
ENV GOFIPS140=latest

RUN apk add --no-cache gcc libc-dev git ca-certificates

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
FROM alpine AS runtime

RUN apk add --no-cache --no-progress ca-certificates tzdata

COPY --from=builder /traefik /traefik

VOLUME ["/etc/traefik"]
EXPOSE 80 443 8080
ENTRYPOINT ["/traefik"]