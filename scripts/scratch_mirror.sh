#!/usr/bin/env bash

# Keep a working copy of this repository on $SCRATCH and bring the keepers back.
#
# WHY. Runs are I/O heavy and highly concurrent, and $PERM is a single NFS filer:
# measured with 30 simultaneous writers, $PERM sustains 530 MB/s against 4863
# MB/s on $SCRATCH, which is Lustre -- a factor of 9.2. So the model, the
# post-processing and the benchmark all belong on $SCRATCH. But $SCRATCH is
# pruned automatically and is not safe for anything you want to keep, so the two
# trees are duals: bulk and scratch work there, results live here.
#
#   push : $PERM -> $SCRATCH   inputs and code (forcing, clim, flux, namelists,
#                              scripts) -- everything a run needs, nothing it
#                              produces
#   pull : $SCRATCH -> $PERM   results only (postprocessed/, benchmark/models/,
#                              benchmark/dashboards/) -- never raw output/, which
#                              is ~30 GB per campaign and regenerable
#   status: what exists on each side
#
# The mirror keeps the same layout as this repository, so every script works
# there unchanged and with no flags: the run scripts derive their project root
# from their own location, and postproc_plumber2.py / benchmark_plumber2.py use
# paths relative to the tree they are run from. The intended cycle is
#
#   scripts/scratch_mirror.sh push
#   cd $SCRATCH/plumber2-ecland
#   scripts/submit_ecland_slurm.sh -x <exe> -i     # -i: output/ in the tree
#   python3 scripts/postproc_plumber2.py --inputdir output --outdir postprocessed
#   python3 scripts/benchmark_plumber2.py
#   cd -; scripts/scratch_mirror.sh pull
#
# WHAT IS NOT COPIED BACK. Raw model output (output/), run state (status/,
# claims/, logs/, slurm/, work/) and the git metadata. Raw output is the biggest
# thing on the scratch side and the cheapest to reproduce; if you need a site's
# restart for an NLOOP=1 rerun, copy that file deliberately rather than the tree.
#
# (C) Copyright 2026- ECMWF.
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
PERM_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
MIRROR="${MIRROR:-${SCRATCH:?SCRATCH is not set}/$(basename "${PERM_ROOT}")}"
DRY_RUN=false

# Inputs a run needs. Code included, so the mirror is self-contained and a run
# there cannot silently use a stale script from a previous campaign.
PUSH_PATHS=(scripts namelists forcing clim flux)

# The executable counts as input. ecland-master-dp resolves its libraries through
# an $ORIGIN/../lib64 rpath, so bin/ and lib64/ have to travel together and keep
# their relative layout. Leaving them on $PERM means every worker demand-pages
# program text and five shared objects over NFS, which with 30 workers on one
# node is served by that node's single NFS client -- the same bottleneck the data
# mirror removes, reintroduced through the loader.
ECLAND_BUILD="${ECLAND_BUILD:-${PERM:-/perm/${USER}}/ecland/build}"
BUILD_SUBDIRS=(bin lib lib64)
MIRROR_BUILD_REL="ecland-build"

# Results worth keeping. Anything not listed stays on $SCRATCH and is lost at the
# next prune, which is the intended behaviour.
PULL_PATHS=(postprocessed benchmark/models benchmark/dashboards)

usage() {
  cat <<EOF
Usage: $(basename "$0") {push|pull|status} [-n] [-M MIRROR]

  push        Copy inputs and code to the mirror (${PUSH_PATHS[*]})
  pull        Copy results back from the mirror (${PULL_PATHS[*]})
  status      Show both sides without copying anything

  -n          Dry run: print what rsync would transfer
  -M MIRROR   Mirror location (default: ${MIRROR})
  -h          Show this help

Deletions are never propagated: rsync runs without --delete in both directions,
so a stale file in the mirror is possible but losing a result is not.
EOF
}

ACTION="${1:-}"
[[ -n "${ACTION}" ]] && shift || true
case "${ACTION}" in
  push|pull|status) ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "ERROR: expected push, pull or status" >&2; usage >&2; exit 2 ;;
esac

while getopts ":hnM:" opt; do
  case "${opt}" in
    n) DRY_RUN=true ;;
    M) MIRROR="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

RSYNC=(rsync -a --human-readable --info=stats1 --exclude '.git' --exclude '__pycache__')
"${DRY_RUN}" && RSYNC+=(--dry-run --itemize-changes)

show_side() {
  local label=$1 root=$2 p
  echo "${label}: ${root}"
  [[ -d "${root}" ]] || { echo "  (does not exist)"; return; }
  for p in scripts namelists forcing clim flux output postprocessed \
           benchmark/models benchmark/dashboards; do
    if [[ -d "${root}/${p}" ]]; then
      printf '  %-22s %8s  %5s entries\n' "${p}" \
        "$(du -sh "${root}/${p}" 2>/dev/null | cut -f1)" \
        "$(find "${root}/${p}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    fi
  done
}

case "${ACTION}" in
  status)
    show_side "PERM  " "${PERM_ROOT}"
    echo
    show_side "SCRATCH" "${MIRROR}"
    ;;

  push)
    echo "push: ${PERM_ROOT} -> ${MIRROR}"
    mkdir -p "${MIRROR}"
    for p in "${PUSH_PATHS[@]}"; do
      if [[ ! -e "${PERM_ROOT}/${p}" ]]; then
        echo "  skip ${p} (absent here)"
        continue
      fi
      echo "  ${p}"
      mkdir -p "$(dirname "${MIRROR}/${p}")"
      "${RSYNC[@]}" "${PERM_ROOT}/${p}/" "${MIRROR}/${p}/"
    done
    if [[ -d "${ECLAND_BUILD}" ]]; then
      echo "  ${MIRROR_BUILD_REL} (from ${ECLAND_BUILD})"
      for sub in "${BUILD_SUBDIRS[@]}"; do
        [[ -d "${ECLAND_BUILD}/${sub}" ]] || continue
        mkdir -p "${MIRROR}/${MIRROR_BUILD_REL}/${sub}"
        "${RSYNC[@]}" "${ECLAND_BUILD}/${sub}/" "${MIRROR}/${MIRROR_BUILD_REL}/${sub}/"
      done
    else
      echo "  skip ${MIRROR_BUILD_REL} (no build at ${ECLAND_BUILD}; set ECLAND_BUILD)"
    fi
    echo
    echo "Mirror ready. Run there, not here, and use the mirrored executable:"
    echo "  cd ${MIRROR}"
    echo "  scripts/submit_ecland_slurm.sh -i \\"
    echo "    -x ${MIRROR}/${MIRROR_BUILD_REL}/bin/ecland-master-dp"
    ;;

  pull)
    echo "pull: ${MIRROR} -> ${PERM_ROOT}"
    [[ -d "${MIRROR}" ]] || { echo "ERROR: no mirror at ${MIRROR}" >&2; exit 1; }
    n_found=0
    for p in "${PULL_PATHS[@]}"; do
      if [[ ! -d "${MIRROR}/${p}" ]]; then
        echo "  skip ${p} (not produced yet)"
        continue
      fi
      echo "  ${p}"
      mkdir -p "${PERM_ROOT}/${p}"
      "${RSYNC[@]}" "${MIRROR}/${p}/" "${PERM_ROOT}/${p}/"
      n_found=$((n_found + 1))
    done
    if [[ "${n_found}" -eq 0 ]]; then
      echo "Nothing to pull: the mirror holds no results yet." >&2
      exit 1
    fi
    echo
    echo "Results are on \$PERM. Raw output stays on \$SCRATCH and will be pruned."
    ;;
esac
