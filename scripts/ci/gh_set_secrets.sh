#!/usr/bin/env bash
# Set GitHub Actions repository secrets from a KEY=VALUE env file.
# Requires: GitHub CLI (gh) authenticated: `gh auth login`
#
# Usage:
#   ./scripts/ci/gh_set_secrets.sh owner/repo path/to/secrets.env
#
# Example:
#   ./scripts/ci/gh_set_secrets.sh PepeluiMoreno/intramurosjerez.org .secrets.staging.env
#
# Notes:
# - Lines starting with # or blank lines are ignored.
# - Supports values with spaces. Quotes are optional in the file.
# - Overwrites existing secrets with the same name.
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI (gh) no está instalado. Véase: https://cli.github.com/" >&2
  exit 1
fi

if [ $# -ne 2 ]; then
  echo "Uso: $0 owner/repo ruta/al/archivo.env" >&2
  exit 1
fi

REPO="$1"
FILE="$2"

if [ ! -f "$FILE" ]; then
  echo "ERROR: No existe el archivo $FILE" >&2
  exit 1
fi

echo "Cargando secrets en $REPO desde $FILE"
while IFS= read -r line || [ -n "$line" ]; do
  # Trim leading/trailing spaces
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  # Skip comments and blanks
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  # Split KEY=VALUE (first '=' only)
  key="${line%%=*}"
  val="${line#*=}"
  # Trim key spaces
  key="${key%"${key##*[![:space:]]}"}"
  key="${key#"${key%%[![:space:]]*}"}"
  # Remove optional surrounding quotes around value
  if [[ "${val:0:1}" == "\"" && "${val: -1}" == "\"" ]]; then
    val="${val:1:-1}"
  elif [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
    val="${val:1:-1}"
  fi
  if [[ -z "$key" ]]; then
    echo "Saltando línea sin clave válida: $line" >&2
    continue
  fi
  echo "  • $key"
  gh secret set "$key" --repo "$REPO" --body "$val" >/dev/null
done < "$FILE"

echo "Hecho."
