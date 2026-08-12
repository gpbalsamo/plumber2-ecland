#!/usr/bin/env bash

# Download the PLUMBER2 meteorological forcing (Met) dataset v1.0 from its
# official NCI THREDDS catalogue.
#
# PLUMBER2 is a model intercomparison project for land surface models,
# built from 170 global FLUXNET/OzFlux/LaThuile eddy-covariance tower
# sites. This script fetches the raw per-site "*_Met.nc" forcing files
# (downward radiation, precipitation, temperature, humidity, wind, etc.)
# used to drive ecLand.
#
# Reference:
#   Ukkola, A. M., Abramowitz, G., and De Kauwe, M. G. (2022): A flux tower
#   dataset tailored for land model evaluation, Earth Syst. Sci. Data, 14,
#   449-461, https://doi.org/10.5194/essd-14-449-2022
#
# Companion script: get_plumber2_flux.sh (observed flux/evaluation data).

set -euo pipefail

CATALOG_URL="${CATALOG_URL:-https://thredds.nci.org.au/thredds/catalog/ks32/CLEX_Data/PLUMBER2/v1-0/Met/catalog.xml}"
FILESERVER_BASE="${FILESERVER_BASE:-https://thredds.nci.org.au/thredds/fileServer}"
OUTDIR="${OUTDIR:-${HOME}/Work/plumber2-ecland/forcing/PLUMBER2_original}"
PATTERN="${PATTERN:-.*\.nc$}"

mkdir -p "${OUTDIR}"

tmp_catalog="$(mktemp)"
tmp_urls="$(mktemp)"
trap 'rm -f "${tmp_catalog}" "${tmp_urls}"' EXIT

echo "Catalogue : ${CATALOG_URL}"
echo "Output dir: ${OUTDIR}"
echo "Pattern   : ${PATTERN}"
echo

curl -fsSL "${CATALOG_URL}" -o "${tmp_catalog}"

python3 - "${tmp_catalog}" "${FILESERVER_BASE}" "${PATTERN}" > "${tmp_urls}" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

catalog_file, fileserver_base, pattern = sys.argv[1:4]
rx = re.compile(pattern)

tree = ET.parse(catalog_file)
root = tree.getroot()

urls = []
for elem in root.iter():
    url_path = elem.attrib.get("urlPath")
    if not url_path:
        continue
    if not rx.search(url_path):
        continue
    urls.append(urljoin(fileserver_base.rstrip("/") + "/", url_path))

for url in sorted(set(urls)):
    print(url)
PY

n=$(wc -l < "${tmp_urls}" | tr -d ' ')
echo "Files found: ${n}"

if [[ "${n}" -eq 0 ]]; then
  echo "ERROR: no files matched ${PATTERN}" >&2
  exit 1
fi

echo
echo "First files:"
head -5 "${tmp_urls}"
echo

while IFS= read -r url; do
  file="$(basename "${url}")"
  out="${OUTDIR}/${file}"

  if [[ -s "${out}" ]]; then
    echo "SKIP existing: ${file}"
    continue
  fi

  echo "GET ${file}"
  curl -fL --retry 5 --retry-delay 10 -C - \
    -o "${out}.part" \
    "${url}"

  mv "${out}.part" "${out}"
done < "${tmp_urls}"

echo
echo "Done. Downloaded files are in:"
echo "${OUTDIR}"
