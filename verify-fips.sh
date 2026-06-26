#!/usr/bin/env bash
# =============================================================================
# verify-fips.sh — Prüft, ob ein Traefik-Binary mit BoringCrypto gebaut wurde
# =============================================================================
# Verwendung:
#   ./verify-fips.sh                          # prüft lokales ./traefik Binary
#   ./verify-fips.sh ghcr.io/org/traefik-fips:v3.3.4-fips   # prüft Image
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET="${1:-./traefik}"
BINARY=""
CLEANUP_DIR=""

# -----------------------------------------------------------------------
# Binary beschaffen: entweder lokal oder aus Docker-Image extrahieren
# -----------------------------------------------------------------------
if [[ -f "$TARGET" ]]; then
  echo "Checking local binary: $TARGET"
  BINARY="$TARGET"
elif [[ "$TARGET" == *"/"* ]] || [[ "$TARGET" == *":"* ]]; then
  echo "Pulling image and extracting binary: $TARGET"
  CLEANUP_DIR=$(mktemp -d)
  CONTAINER_ID=$(docker create "$TARGET" /bin/sh 2>/dev/null || \
                 docker create "$TARGET" 2>/dev/null)
  docker cp "${CONTAINER_ID}:/traefik" "${CLEANUP_DIR}/traefik"
  docker rm "${CONTAINER_ID}" >/dev/null
  BINARY="${CLEANUP_DIR}/traefik"
else
  echo -e "${RED}❌ Datei oder Image nicht gefunden: $TARGET${NC}"
  exit 1
fi

# -----------------------------------------------------------------------
# Check 1: go tool nm — sucht nach BoringCrypto-Symbolen
# -----------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Check 1: BoringCrypto-Symbole (go tool nm)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if go tool nm "$BINARY" 2>/dev/null | grep -q "_Cfunc__goboringcrypto_"; then
  BORING_COUNT=$(go tool nm "$BINARY" 2>/dev/null | grep -c "_Cfunc__goboringcrypto_" || true)
  echo -e "${GREEN}✅ BoringCrypto-Symbole gefunden: ${BORING_COUNT} Funktionen${NC}"
  BORING_RESULT=0
else
  echo -e "${RED}❌ Keine BoringCrypto-Symbole gefunden!${NC}"
  BORING_RESULT=1
fi

# -----------------------------------------------------------------------
# Check 2: strings — Suche nach FIPS/BoringCrypto Strings im Binary
# -----------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Check 2: FIPS/BoringCrypto Strings im Binary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if strings "$BINARY" 2>/dev/null | grep -qi "boringcrypto\|fips"; then
  echo -e "${GREEN}✅ FIPS/BoringCrypto Strings gefunden:${NC}"
  strings "$BINARY" | grep -i "boringcrypto\|fips" | head -10 | sed 's/^/   /'
  STRINGS_RESULT=0
else
  echo -e "${YELLOW}⚠️  Keine expliziten FIPS-Strings gefunden (kann bei -s stripped Binary normal sein)${NC}"
  STRINGS_RESULT=0  # nicht kritisch
fi

# -----------------------------------------------------------------------
# Check 3: rsc.io/goversion (optional, aber am zuverlässigsten)
# -----------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Check 3: goversion -crypto (empfohlenes Tool von Go-Team)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if command -v goversion >/dev/null 2>&1; then
  GOVERSION_OUT=$(goversion -crypto "$BINARY" 2>&1 || true)
  echo "$GOVERSION_OUT"
  if echo "$GOVERSION_OUT" | grep -qi "boring"; then
    echo -e "${GREEN}✅ goversion bestätigt BoringCrypto${NC}"
    GOVERSION_RESULT=0
  else
    echo -e "${YELLOW}⚠️  goversion zeigt kein BoringCrypto — prüfe manuell${NC}"
    GOVERSION_RESULT=1
  fi
else
  echo -e "${YELLOW}⚠️  goversion nicht installiert. Installieren mit:${NC}"
  echo "   go install rsc.io/goversion@latest"
  GOVERSION_RESULT=99  # nicht verfügbar
fi

# -----------------------------------------------------------------------
# Aufräumen
# -----------------------------------------------------------------------
if [[ -n "$CLEANUP_DIR" ]]; then
  rm -rf "$CLEANUP_DIR"
fi

# -----------------------------------------------------------------------
# Zusammenfassung
# -----------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Ergebnis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $BORING_RESULT -eq 0 ]]; then
  echo -e "${GREEN}✅ Binary ist mit BoringCrypto (FIPS 140-2) kompiliert.${NC}"
  echo ""
  echo -e "${YELLOW}ℹ️  Hinweis: Dies bestätigt die Nutzung von BoringCrypto,${NC}"
  echo -e "${YELLOW}   aber keine formale FIPS-140-2-Zertifizierung des Produkts.${NC}"
  exit 0
else
  echo -e "${RED}❌ Binary ist NICHT mit BoringCrypto kompiliert.${NC}"
  echo "   Mögliche Ursachen:"
  echo "   - GOEXPERIMENT=boringcrypto war beim Build nicht gesetzt"
  echo "   - CGO_ENABLED=0 war gesetzt (BoringCrypto benötigt CGO)"
  echo "   - Falsches Basis-Image (nur Linux amd64/arm64 unterstützt)"
  exit 1
fi
