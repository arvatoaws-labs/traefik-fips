# =============================================================================
# Stage 1: Build Traefik with GOEXPERIMENT=boringcrypto (FIPS-konformes Crypto)
# =============================================================================
FROM golang:1.23-bullseye AS builder

# CGO muss aktiv sein, damit BoringCrypto gelinkt werden kann
ENV CGO_ENABLED=1
ENV GOEXPERIMENT=boringcrypto
ENV GOOS=linux
ENV GOARCH=amd64

# Build-Abhängigkeiten (für CGO/BoringCrypto nötig)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Traefik-Quellcode (geforktes Repo wird per ARG übergeben)
ARG TRAEFIK_VERSION=v3.3.4
RUN git clone --depth=1 --branch=${TRAEFIK_VERSION} \
    https://github.com/traefik/traefik.git .

# Go-Module cachen
RUN go mod download

# WebUI-Assets generieren (Traefik bringt eine vorgebaute WebUI mit)
# Falls du die WebUI nicht brauchst, kann dieser Schritt entfallen
# und stattdessen: go generate ./...
RUN mkdir -p webui/static && \
    echo "placeholder" > webui/static/SKIP && \
    go generate ./...

# Binary kompilieren mit BoringCrypto
# -trimpath: reproduzierbarer Build
# Die ldflags setzen die Version sauber
RUN go build \
    -trimpath \
    -ldflags="-s -w \
      -X github.com/traefik/traefik/v3/pkg/version.Version=${TRAEFIK_VERSION} \
      -X github.com/traefik/traefik/v3/pkg/version.Codename=fips \
      -X github.com/traefik/traefik/v3/pkg/version.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o /traefik \
    ./cmd/traefik/

# =============================================================================
# Stage 2: Verify — prüfen, ob BoringCrypto wirklich gelinkt wurde
# =============================================================================
FROM builder AS verify
RUN go tool nm /traefik | grep -q "_Cfunc__goboringcrypto_" && \
    echo "✅ BoringCrypto verified in binary" || \
    (echo "❌ BoringCrypto NOT found — build failed!" && exit 1)

# =============================================================================
# Stage 3: Minimales Laufzeit-Image (analog zum offiziellen Traefik-Image)
# =============================================================================
FROM gcr.io/distroless/base-debian12:nonroot AS runtime

# Traefik-Binary aus dem Builder übernehmen
COPY --from=builder /traefik /traefik

# Konfigurationsverzeichnis
VOLUME ["/etc/traefik"]

EXPOSE 80 443 8080

ENTRYPOINT ["/traefik"]
