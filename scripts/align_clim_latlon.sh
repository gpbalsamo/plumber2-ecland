#!/usr/bin/env bash

# Align the site metadata in clim/PLUMBER2/surfclim_<site>.nc and
# surfinit_<site>.nc with the corresponding
# forcing/PLUMBER2/met_insituHT_<site>.nc file:
#
#   lat, lon          (surfclim + surfinit) <- forcing latitude/longitude
#   zphista, zuv      (surfclim only)       <- forcing reference_height
#
# zphista/zuv are the reference levels for T/q and for wind, i.e. the height
# at which the in-situ forcing is taken to be measured; the forcing file's
# reference_height ("Reference height of flux tower", source = measurement
# height) is the authoritative value. Some surfclim releases ship a constant
# 10 m for every site instead, which misstates the surface layer for towers
# that are anywhere from 1.5 m to 122 m tall across PLUMBER2. These feed
# ZPHISTA/ZUV in &NAMFORC via ecland_create_namelist.py.
#
# This only overwrites those scalar values in-place; it does NOT re-derive the
# soil/vegetation/orography/climatology fields for the new coordinate -- those
# still reflect whatever location the surfclim/surfinit files were originally
# built for. This script is a metadata fix, not a re-extraction of the static
# fields at the forcing's site location.
#
# zphista/zuv are written with an index assignment (`zphista(0)=`) so the
# variable keeps its declared type and shape whether the surfclim release
# carries them as 2D (lat, lon) fields (climate.v015) or as 0-d scalars
# (climv21).
#
# Requires: NCO (ncap2) -- `module load nco` on the ECMWF HPC -- and
# forcing/PLUMBER2/ already populated (see regenerate_plumber2_forcing.sh).
#
# (C) Copyright 2023- ECMWF.
#
# Licensed under the Apache Licence Version 2.0:
# http://www.apache.org/licenses/LICENSE-2.0
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation,
# nor does it submit to any jurisdiction.

set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

FORCING_DIR="${FORCING_DIR:-${PROJECT_ROOT}/forcing/PLUMBER2}"
CLIM_DIR="${CLIM_DIR:-${PROJECT_ROOT}/clim/PLUMBER2}"

# Print the scalar value of a netCDF variable that appears as:
#   varname =
#     123.456 ;
get_val() {
  local file="$1" var="$2"
  ncks -H -C -v "${var}" "${file}" | awk -v v="${var}" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=[[:space:]]*$" { getline; gsub(/[ ;]/,""); print; exit }
  '
}

shopt -s nullglob
forcing_files=("${FORCING_DIR}"/met_insituHT_*.nc)
shopt -u nullglob

if [[ ${#forcing_files[@]} -eq 0 ]]; then
  echo "ERROR: no forcing files found in ${FORCING_DIR}" >&2
  exit 1
fi

echo "Forcing: ${FORCING_DIR} (${#forcing_files[@]} files)"
echo "Clim   : ${CLIM_DIR}"
echo

n=0
skipped=0
no_height=0
for f in "${forcing_files[@]}"; do
  base="$(basename "${f}" .nc)"
  # met_insituHT_<SITE>_<years> -> <SITE>_<years>
  site_years="${base#met_insituHT_}"

  surfclim="${CLIM_DIR}/surfclim_${site_years}.nc"
  surfinit="${CLIM_DIR}/surfinit_${site_years}.nc"

  if [[ ! -f "${surfclim}" || ! -f "${surfinit}" ]]; then
    echo "SKIP (missing clim files): ${site_years}" >&2
    skipped=$((skipped + 1))
    continue
  fi

  flat=$(get_val "${f}" latitude)
  flon=$(get_val "${f}" longitude)
  fhgt=$(get_val "${f}" reference_height)

  if [[ -z "${flat}" || -z "${flon}" ]]; then
    echo "SKIP (no latitude/longitude in forcing file): ${site_years}" >&2
    skipped=$((skipped + 1))
    continue
  fi

  ncap2 -O -h -s "lat(0)=${flat}; lon(0)=${flon}" "${surfclim}" "${surfclim}"
  ncap2 -O -h -s "lat(0)=${flat}; lon(0)=${flon}" "${surfinit}" "${surfinit}"

  # Leave zphista/zuv untouched rather than write a bad height if the forcing
  # file carries no usable reference_height (missing, fill value or <= 0).
  if [[ -z "${fhgt}" ]] || ! awk -v h="${fhgt}" 'BEGIN{exit !(h+0 > 0 && h != -9999)}'; then
    echo "[$((n + 1))] ${site_years}: lat=${flat} lon=${flon}  (no usable reference_height; zphista/zuv left as-is)" >&2
    no_height=$((no_height + 1))
    n=$((n + 1))
    continue
  fi

  ncap2 -O -h -s "zphista(0)=${fhgt}; zuv(0)=${fhgt}" "${surfclim}" "${surfclim}"

  n=$((n + 1))
  echo "[${n}] ${site_years}: lat=${flat} lon=${flon} zphista=zuv=${fhgt}"
done

echo
echo "Done: aligned ${n} sites, skipped ${skipped}, ${no_height} without a usable reference_height."
