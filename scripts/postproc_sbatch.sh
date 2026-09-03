#!/bin/bash
#SBATCH -n 1
#SBATCH -t 00:30:00

# Post-process one PLUMBER2 site as a SLURM job.
#
# Submitted by scripts/postproc_run_experiment.sh under LBATCH=true, one job
# per site, parameters arriving through --export -- the same convention
# scripts/run_sbatch.sh uses for the model-run stage.
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

module load python3/3.10.10-01

trace() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

# EXTRA_ARGS is a single space-separated string (e.g. "--overwrite --strict"),
# not an array -- sbatch --export only carries scalar environment strings, so
# it is deliberately word-split below rather than quoted.
trace python3 "${POSTPROC_SCRIPT}" \
    --inputdir "${INPUT_DIR}" \
    --outdir "${OUTPUT_DIR}" \
    --site "${SITE}" \
    ${EXTRA_ARGS:-}
