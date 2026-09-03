#!/usr/bin/env bash

# Post-process a whole PLUMBER2 output tree in parallel.
#
# scripts/postproc_plumber2.py itself loops over sites one at a time, which is
# fine for a handful of sites but leaves 169 of the 170 site's worth of CPU
# idle when you have a whole node. This wrapper fans that out over PARALLEL
# workers, one site per worker slot at a time, so a slow site never blocks
# the rest of the queue behind it.
#
# Two modes, selected the same way as ecland_run_experiment.sh:
#
#   Local (default)   Runs up to -j sites at once as background processes on
#                      the current node, using ordinary bash job control.
#   LBATCH=true        Submits one SLURM job per site (scripts/postproc_sbatch.sh),
#                      keeping at most -j queued/running at a time -- the same
#                      poll/wait_for_slot pattern ecland_run_experiment.sh uses
#                      for the model-run stage.
#
# Usage:
#   scripts/postproc_run_experiment.sh -i output -o postprocessed -j 25
#   LBATCH=true scripts/postproc_run_experiment.sh -i output -o postprocessed -j 25
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

trace() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# Relative to the working directory, matching postproc_plumber2.py's own
# convention -- run from the repository (or $SCRATCH mirror) tree, not from
# scripts/.
INPUT_DIR="output"
OUTPUT_DIR="postprocessed"
PARALLEL=1
SITE_LIST_FILE=""
OVERWRITE=false
STRICT=false
NO_COMPRESSION=false
DRY_RUN=false
POSTPROC_SCRIPT="${SCRIPT_DIR}/postproc_plumber2.py"

# LBATCH-only.
WALLTIME="00:30:00"
QOS="nf"
MEM_PER_CPU="4G"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  -i INPUT_DIR     Raw ecLand output, one <site>_<years>/ per site
                     (default: ${INPUT_DIR})
  -o OUTPUT_DIR    Where the PLUMBER2-schema files are written
                     (default: ${OUTPUT_DIR})
  -j PARALLEL      Sites to post-process at once (default: ${PARALLEL}).
                     Local mode: concurrent background processes on this
                     node. LBATCH=true: queued/running SLURM jobs at a time.
  -S SITE_LIST_FILE  Restrict to these sites, one <site>_<Y1>-<Y2> per line
                     (default: every directory under INPUT_DIR)
  -O               Overwrite existing postprocessed files (--overwrite)
  -k               Strict mode: fail a site on any missing field (--strict)
  -Z               Disable NetCDF compression (--no-compression)
  -T WALLTIME      Per-job wall limit, LBATCH only (default: ${WALLTIME})
  -q QOS           SLURM QoS, LBATCH only (default: ${QOS})
  -M MEM_PER_CPU   Memory per job, LBATCH only (default: ${MEM_PER_CPU})
  -x POSTPROC_SCRIPT  Path to postproc_plumber2.py
                     (default: ${POSTPROC_SCRIPT})
  -d               Dry run: list the sites that would be processed and exit
  -h               Show this help

Examples:
  $(basename "$0") -i output -o postprocessed -j 25
  LBATCH=true $(basename "$0") -i output -o postprocessed -j 25
EOF
}

while getopts ":hi:o:j:S:OkZT:q:M:x:d" opt; do
  case "${opt}" in
    i) INPUT_DIR="${OPTARG}" ;;
    o) OUTPUT_DIR="${OPTARG}" ;;
    j) PARALLEL="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    O) OVERWRITE=true ;;
    k) STRICT=true ;;
    Z) NO_COMPRESSION=true ;;
    T) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    x) POSTPROC_SCRIPT="${OPTARG}" ;;
    d) DRY_RUN=true ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "${PARALLEL}" =~ ^[0-9]+$ || "${PARALLEL}" -lt 1 ]]; then
  echo "ERROR: -j PARALLEL must be a positive integer, got '${PARALLEL}'" >&2
  exit 2
fi
if [[ ! -d "${INPUT_DIR}" ]]; then
  echo "ERROR: input directory does not exist: ${INPUT_DIR}" >&2
  exit 1
fi
if [[ ! -f "${POSTPROC_SCRIPT}" ]]; then
  echo "ERROR: postproc script not found: ${POSTPROC_SCRIPT}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Site list
# ---------------------------------------------------------------------------

if [[ -n "${SITE_LIST_FILE}" ]]; then
  if [[ ! -f "${SITE_LIST_FILE}" ]]; then
    echo "ERROR: site list file not found: ${SITE_LIST_FILE}" >&2
    exit 1
  fi
  mapfile -t SITES < <(grep -v '^ *#' "${SITE_LIST_FILE}" | grep -v '^ *$')
else
  mapfile -t SITES < <(find "${INPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi

if [[ ${#SITES[@]} -eq 0 ]]; then
  echo "ERROR: no site directories found under ${INPUT_DIR}" >&2
  exit 1
fi

echo "Input directory : ${INPUT_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Sites           : ${#SITES[@]}"
echo "Parallel        : ${PARALLEL} ($([[ "${LBATCH:-false}" == true ]] && echo "LBATCH, SLURM jobs" || echo "local processes"))"

if [[ "${DRY_RUN}" == true ]]; then
  printf '%s\n' "${SITES[@]}"
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"

EXTRA_ARGS=()
if [[ "${OVERWRITE}" == true ]]; then EXTRA_ARGS+=(--overwrite); fi
if [[ "${STRICT}" == true ]]; then EXTRA_ARGS+=(--strict); fi
if [[ "${NO_COMPRESSION}" == true ]]; then EXTRA_ARGS+=(--no-compression); fi
EXTRA_ARGS_STR="${EXTRA_ARGS[*]:-}"

LOG_DIR="${OUTPUT_DIR%/}.postproc_logs"
STATUS_DIR="${LOG_DIR}/status"
mkdir -p "${STATUS_DIR}"

# ---------------------------------------------------------------------------
# LBATCH mode: one SLURM job per site, at most PARALLEL queued/running.
# ---------------------------------------------------------------------------

if [[ "${LBATCH:-false}" == true ]]; then
  declare -a job_ids=()

  poll_jobs() {
    local active=()
    local jid status
    for jid in "${job_ids[@]}"; do
      status=$(
        scontrol show job "${jid}" 2>/dev/null |
          awk -F'JobState=' 'NF > 1 {print $2}' | awk '{print $1}'
      )
      if [[ "${status}" == "PENDING"     ||
            "${status}" == "RUNNING"     ||
            "${status}" == "CONFIGURING" ||
            "${status}" == "COMPLETING" ]]; then
        active+=("${jid}")
      else
        echo "Job ${jid} finished with state: ${status:-unknown}"
      fi
    done
    job_ids=("${active[@]+"${active[@]}"}")
  }

  wait_for_slot() {
    while [[ ${#job_ids[@]} -ge ${PARALLEL} ]]; do
      sleep 10
      poll_jobs
    done
  }

  site_num=0
  for site in "${SITES[@]}"; do
    site_num=$(( site_num + 1 ))
    wait_for_slot

    job_output=$(
      sbatch \
        --job-name="postproc_${site}" \
        --time="${WALLTIME}" \
        --qos="${QOS}" \
        --mem-per-cpu="${MEM_PER_CPU}" \
        --output="${LOG_DIR}/${site}.out" \
        --export="POSTPROC_SCRIPT=${POSTPROC_SCRIPT},INPUT_DIR=${INPUT_DIR},OUTPUT_DIR=${OUTPUT_DIR},SITE=${site},EXTRA_ARGS=${EXTRA_ARGS_STR}" \
        "${SCRIPT_DIR}/postproc_sbatch.sh"
    ) || { echo "ERROR: sbatch failed for site ${site}" >&2; echo FAILED > "${STATUS_DIR}/${site}"; continue; }

    job_id=$(awk '{print $4}' <<<"${job_output}")
    if [[ -z "${job_id}" ]]; then
      echo "ERROR: could not extract job ID for site ${site} (sbatch output: ${job_output})" >&2
      echo FAILED > "${STATUS_DIR}/${site}"
      continue
    fi
    job_ids+=("${job_id}")
    echo "Submitted SLURM job ${job_id} for ${site} (active: ${#job_ids[@]}/${PARALLEL} ; site ${site_num} of ${#SITES[@]})"
  done

  if [[ ${#job_ids[@]} -gt 0 ]]; then
    echo "Waiting for ${#job_ids[@]} remaining job(s) to finish..."
    while [[ ${#job_ids[@]} -gt 0 ]]; do
      sleep 10
      poll_jobs
    done
  fi

  echo
  echo "All post-processing jobs finished -- check ${LOG_DIR}/*.out for per-site logs."
  exit 0
fi

# ---------------------------------------------------------------------------
# Local mode: up to PARALLEL sites at once as background processes.
# ---------------------------------------------------------------------------

for site in "${SITES[@]}"; do
  while [[ "$(jobs -rp | wc -l)" -ge "${PARALLEL}" ]]; do
    wait -n
  done

  (
    if trace python3 "${POSTPROC_SCRIPT}" \
        --inputdir "${INPUT_DIR}" \
        --outdir "${OUTPUT_DIR}" \
        --site "${site}" \
        "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
        > "${LOG_DIR}/${site}.out" 2>&1; then
      echo OK > "${STATUS_DIR}/${site}"
    else
      echo FAILED > "${STATUS_DIR}/${site}"
    fi
  ) &
done
wait

# grep exits 1 on no match, which with pipefail would poison the pipeline
# and, under set -e, abort the script right here even on full success --
# hence the `|| true` on each.
n_ok=$(grep -lx OK "${STATUS_DIR}"/* 2>/dev/null | wc -l | tr -d ' ') || true
n_failed=$(grep -lx FAILED "${STATUS_DIR}"/* 2>/dev/null | wc -l | tr -d ' ') || true
echo
echo "Done: ${n_ok} written, ${n_failed} failed (of ${#SITES[@]})."
echo "Per-site logs: ${LOG_DIR}/<site>.out"
if [[ "${n_failed}" -gt 0 ]]; then
  echo "Failed sites:"
  grep -lx FAILED "${STATUS_DIR}"/* | xargs -n1 basename
  exit 1
fi
