#!/usr/bin/env bash

# Run ecLand over a whole site group as a SLURM job array, then leave the
# output ready for scripts/postproc_plumber2.py and scripts/benchmark_plumber2.py.
#
# This is the fast path, and the alternative to the LBATCH=true mode of
# ecland_run_experiment.sh, which submits one job per site, caps itself at
# MAX_CONCURRENT=25, and holds a login-node poller open until the last site
# finishes. Here a single array submission gives up to ARRAY_TASKS concurrent
# sites, nothing has to stay alive on the login node, and a failure or a
# wall-limit kill costs exactly one site.
#
# Array elements are interchangeable WORKERS draining one shared queue, not
# owners of a fixed slice -- see scripts/ecland_run_queue.sh for the claim and
# status mechanics. Sites run from 1 to 21 years here, so with fixed slices the
# finish time is set by whichever worker draws the worst combination, while a
# queue reaches max(total/N, longest single site).
#
# A site is claimed, run and recorded individually, so the run is resumable:
# statuses seeded from existing output are skipped, which also makes switching
# strategies or retrying failures mid-flight free.
#
# A single point integration is serial: no launcher, one CPU per worker, and
# concurrency is ARRAY_TASKS x WORKERS_PER_TASK.
#
# COST. Cost tracks TIMESTEPS, not years -- PLUMBER2 mixes half-hourly and hourly
# forcing, so a 17-year site measured 3106 s against 1835 s for a 21-year one.
# Measured over a complete 170-site run at NLOOP=2 with -a 2 -w 30: 14.0 ms per
# timestep, 6.8% median error, no useful intercept. The group is 17.1 M timesteps,
# so a full run is 63 CPU-hours, 69 minutes of wall clock, and 131 GB of raw
# output -- about 770 MB per site, which is why raw output belongs on $SCRATCH.
# Refit rather than reuse: the same law over FLUXNET Shuttle sites gives 194 s per
# site-year against 86 here, so nothing transfers between the two repositories.
# len(time) from each forcing file is the predictor.
#
# HOW MANY WORKERS. Concurrency is ARRAY_TASKS x WORKERS_PER_TASK, and the two
# are not interchangeable, because the scarce resource is job slots rather than
# CPUs: `sacctmgr show assoc user=$USER` gives MaxJobs=30 per account on QoS nf,
# and array elements count individually, so element 31 and up sit in PENDING
# (AssocMaxJobsLimit). Raising -a past 30 therefore does nothing, while -w buys
# concurrency out of a node's CPUs instead -- these nodes carry 256 of them.
#
# So -a 2 -w 30 gives 60 concurrent sites for 2 job slots, where -a 25 -w 1 gives
# 25 for 25. Both leave the run resumable and the claims safe: workers inside one
# element claim by the same atomic mkdir as workers across nodes.
#
# 60 is the number worth remembering for this group. Concurrency stops paying at
# the FLOOR of 1.16 h -- FI-Hyy 1996-2014, 333,120 half-hourly timesteps, measured
# at 4178 s, the costliest single site and serial so it cannot be split. Note it
# is NOT the longest record: US-Ha1 spans 21 years but hourly, so it is half the
# work. 60 workers already reach that floor (63 CPU-h / 60 = 1.05 h < 1.16 h);
# measured, an LPT schedule over the real per-site costs gives 1.16 h at both 60
# and 120 workers, and the complete run finished in 69 minutes. Going to 180, as
# the Shuttle does with -a 5 -w 36, is right for 775 sites and 3x oversized for
# 170. Below the floor, halving the work is the only lever left: NLOOP=1 from an
# equilibrated restart.
#
# WALL LIMIT. Size it on the per-worker DRAIN time, not on one site: a worker
# takes site after site until the queue is empty, so it lives for roughly
# total/N -- 2.5 h at 25 workers, 1.05 h at 60 -- but never below the costliest
# single site, 1.16 h, since one worker must carry it to the end. The 02:30:00
# default leaves about 60% margin over that floor: the measured run took 69 min
# and a 02:00:00 limit came within 10 minutes of killing it. Raise it further if
# you cut concurrency below 60. A worker killed at the limit loses only its
# in-flight site (the claim is swept and the site retried next submission), but a
# limit below the drain means every worker dies mid-queue and nothing is recorded:
# that mistake cost 91 CPU-hours here for zero sites.
#
# I/O AND WHERE TO RUN. Run on $SCRATCH, not here. Measured with 30 concurrent
# writers, $PERM (NFS) sustains 530 MB/s against 4863 MB/s on Lustre, and the
# reads matter as much -- workers inside one element share that node's single NFS
# client, forcing included. The executable counts too: it demand-pages five shared
# objects through an $ORIGIN/../lib64 rpath. scripts/scratch_mirror.sh push
# assembles a self-contained tree on $SCRATCH, including the build; run there with
# -i and pull the results back.
#
# Usage:
#   scripts/submit_ecland_slurm.sh -x ECLAND_MASTER [options]
#
#   scripts/submit_ecland_slurm.sh \
#     -x /perm/pad/ecland/build/bin/ecland-master-dp -a 2 -w 30 -O ${SCRATCH}
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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

GROUP="PLUMBER2"
ECLAND_MASTER="${ECLAND_MASTER:-${PERM:-/perm/${USER}}/ecland/build/bin/ecland-master-dp}"
FORCING_TYPE="insitu"
NLOOP=2
# Concurrency is ARRAY_TASKS x WORKERS_PER_TASK = 60, which reaches this group's
# measured 1.16 h floor while consuming 2 of the 30 job slots the association
# allows -- see "HOW MANY WORKERS" above. WALLTIME clears that floor with margin;
# raise it if you drop concurrency below 60 workers, where the drain rather than
# the floor sets the finish.
ARRAY_TASKS=2
WORKERS_PER_TASK=30
THROTTLE=""
WALLTIME="02:30:00"
QOS="nf"
# A single-point run needs very little: the sibling repo runs 26-year records at
# 2G. This is per CPU, so it multiplies by -w -- at 8G, -w 36 would reserve
# 288 GB of a 480 GB node for no reason.
MEM_PER_CPU="2G"
NAMELIST="${PROJECT_ROOT}/namelists/namelist_ecland_50R1_ctl"
OUT_ROOT="${OUT_ROOT:-${PROJECT_ROOT}}"
SITE_LIST_FILE=""
DRY_RUN=false
IN_PLACE=false

# A completed site holds the full set of model files. PLUMBER2 runs write 13
# o_*.nc diagnostics plus restartout.nc; requiring the restart as well as the
# count keeps a half-written directory from being seeded as done.
MIN_OUTPUT_NC=14

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  -g GROUP          Site group under forcing/ and clim/ (default: ${GROUP})
  -x ECLAND_MASTER  ecLand executable (default: ${ECLAND_MASTER})
  -t FORCING_TYPE   Forcing type passed to the run script (default: ${FORCING_TYPE})
  -l NLOOP          Spin-up loops over the forcing period (default: ${NLOOP})
  -a ARRAY_TASKS    Array elements (default: ${ARRAY_TASKS}). Each counts against
                     the association MaxJobs of 30 on QoS ${QOS}, so past 30 this
                     only adds PENDING elements. Surplus elements exit when the
                     queue drains, so it need not divide the site count
  -w WORKERS        Parallel workers INSIDE each element (default:
                     ${WORKERS_PER_TASK}), taking one CPU each. Concurrency is
                     ARRAY_TASKS x WORKERS, so -w is the way past MaxJobs:
                     -a 2 -w 30 gives 60 concurrent sites for 2 job slots.
                     Lowering total concurrency lengthens the drain -- raise -T
  -p THROTTLE       Cap simultaneously running elements (SLURM's --array=..%N)
  -S SITE_LIST_FILE Restrict to these sites, one <site>_<Y1>-<Y2> per line
  -n NAMELIST       Namelist template (default: ${NAMELIST})
  -T WALLTIME       Per-task wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -O OUT_ROOT       Parent of the run root ecland_<GROUP>/ holding output/,
                     work/, logs/ and the queue state (default: ${OUT_ROOT}).
                     Use -O \${SCRATCH} to keep raw output off \$PERM
  -i                In place: make the run root OUT_ROOT itself, so output/ sits
                     directly in the tree as postproc_plumber2.py and
                     benchmark_plumber2.py expect. Intended for the \$SCRATCH
                     mirror (see scripts/scratch_mirror.sh); on \$PERM it would
                     seed from this repository's existing output/
  -d                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hdig:x:t:l:a:w:p:S:n:T:q:M:O:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    t) FORCING_TYPE="${OPTARG}" ;;
    l) NLOOP="${OPTARG}" ;;
    a) ARRAY_TASKS="${OPTARG}" ;;
    w) WORKERS_PER_TASK="${OPTARG}" ;;
    p) THROTTLE="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    n) NAMELIST="${OPTARG}" ;;
    T) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    O) OUT_ROOT="${OPTARG}" ;;
    d) DRY_RUN=true ;;
    i) IN_PLACE=true ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -x "${ECLAND_MASTER}" ]]; then
  echo "ERROR: ecLand executable not found or not executable: ${ECLAND_MASTER}" >&2
  exit 1
fi
if [[ ! -f "${NAMELIST}" ]]; then
  echo "ERROR: namelist template not found: ${NAMELIST}" >&2
  exit 1
fi

FORCING_DIR="${PROJECT_ROOT}/forcing/${GROUP}"
CLIM_DIR="${PROJECT_ROOT}/clim/${GROUP}"
for d in "${FORCING_DIR}" "${CLIM_DIR}"; do
  [[ -d "${d}" ]] || { echo "ERROR: missing ${d}" >&2; exit 1; }
done

if squeue -u "${USER}" -h -n "ecland_${GROUP}" 2>/dev/null | grep -q .; then
  echo "ERROR: a job named ecland_${GROUP} is already queued or running." >&2
  echo "       Sweeping claims while it runs would double-run sites. Cancel it first." >&2
  exit 1
fi

# -i puts output/ directly in the tree, matching the $PERM layout that
# postproc_plumber2.py and benchmark_plumber2.py expect; otherwise the run
# gets its own ecland_<GROUP>/ so it cannot seed from a pre-existing output/.
if [[ "${IN_PLACE}" == true ]]; then
  RUN_ROOT="${OUT_ROOT}"
else
  RUN_ROOT="${OUT_ROOT}/ecland_${GROUP}"
fi
SLURM_DIR="${RUN_ROOT}/slurm"

# Raw output is written by every worker at once, and $PERM is NFS. Past roughly
# 25 simultaneous writers that is the wrong target, so say so rather than let a
# run crawl -- but only warn, since keeping an existing run root is often the
# better trade (moving it forfeits the completed sites seeded from it).
# Test the filesystem type rather than the path: $SCRATCH resolves through
# /ec/res4/scratch to /lus/..., so a prefix match on either spelling misfires.
FS_TYPE="$(stat -f -c %T "${RUN_ROOT}" 2>/dev/null || echo unknown)"
if [[ $((ARRAY_TASKS * WORKERS_PER_TASK)) -gt 25 && "${FS_TYPE}" != "lustre" ]]; then
  echo "NOTE: $((ARRAY_TASKS * WORKERS_PER_TASK)) concurrent writers into ${RUN_ROOT}"
  echo "      on a ${FS_TYPE} filesystem. Measured with 30 writers, \$PERM (NFS)"
  echo "      sustains 530 MB/s against 4863 MB/s on Lustre -- and the workers also"
  echo "      READ forcing and clim, which is what actually stalls them. Use the"
  echo "      \$SCRATCH mirror: scripts/scratch_mirror.sh push"
fi
# The inputs matter as much as the output: 30 workers on one node share that
# node's NFS client, so forcing read over NFS starves them even when output is on
# Lustre (measured: 7% CPU per worker, no site finishing in 40 min).
IN_FS="$(stat -f -c %T "${FORCING_DIR}" 2>/dev/null || echo unknown)"
if [[ $((ARRAY_TASKS * WORKERS_PER_TASK)) -gt 25 && "${IN_FS}" != "lustre" ]]; then
  echo "NOTE: forcing is on a ${IN_FS} filesystem (${FORCING_DIR})."
  echo "      Run from the \$SCRATCH mirror instead, or concurrency will not pay."
fi
mkdir -p "${SLURM_DIR}" "${RUN_ROOT}/output" "${RUN_ROOT}/work"

# A site is only runnable if BOTH its forcing and its physiography exist, and
# ecland_run_model.sh pairs them by the <site>_<Y1>-<Y2> stem, so check that
# stem rather than the site code. Reporting the gap here beats discovering it
# as a failed task per missing site.
FULL_LIST="${SLURM_DIR}/runnable_sites.txt"
if [[ -n "${SITE_LIST_FILE}" ]]; then
  awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") } $0 != "" && !seen[$0]++' \
    "${SITE_LIST_FILE}" > "${FULL_LIST}"
else
  comm -12 \
    <(find "${FORCING_DIR}" -name "met_${FORCING_TYPE}HT_*.nc" -printf '%f\n' \
        | sed -E "s/^met_${FORCING_TYPE}HT_(.+)\.nc$/\1/" | sort) \
    <(find "${CLIM_DIR}" -name 'surfclim_*.nc' -printf '%f\n' \
        | sed -E 's/^surfclim_(.+)\.nc$/\1/' | sort) > "${FULL_LIST}"
fi

n_forcing=$(find "${FORCING_DIR}" -name "met_${FORCING_TYPE}HT_*.nc" | wc -l | tr -d ' ')
n_clim=$(find "${CLIM_DIR}" -name 'surfclim_*.nc' | wc -l | tr -d ' ')
n_sites=$(wc -l < "${FULL_LIST}" | tr -d ' ')
if [[ "${n_sites}" -eq 0 ]]; then
  echo "ERROR: no site has both forcing and physiography in ${GROUP}" >&2
  exit 1
fi
# Only trim when each element is one site; with -w the element count is a
# resource shape, not a site count, and must be left alone.
if [[ "${ARRAY_TASKS}" -gt "${n_sites}" && "${WORKERS_PER_TASK}" -eq 1 ]]; then
  echo "NOTE: ${ARRAY_TASKS} tasks requested for ${n_sites} sites -- using ${n_sites}."
  ARRAY_TASKS="${n_sites}"
fi

QUEUE="${SLURM_DIR}/queue.txt"
# Longest first. With a queue this is the classic scheduling win: start the
# 21-year records before the 1-year ones and the long tail is absorbed by the
# short jobs instead of being left to run alone at the end.
awk -F'[_-]' '{print $(NF-1)-$NF, $0}' "${FULL_LIST}" \
  | sort -k1,1n | cut -d' ' -f2- > "${QUEUE}" || cp "${FULL_LIST}" "${QUEUE}"

STATUS_DIR="${RUN_ROOT}/status"
CLAIM_DIR="${RUN_ROOT}/claims"
mkdir -p "${STATUS_DIR}" "${CLAIM_DIR}"

# Seed status from output already on disk, so a previous run's work is not
# repeated. To force a site to run again, delete its status file (or its output
# directory); to retry only the failures, see the Retry hint printed below.
n_seeded=0
for d in "${RUN_ROOT}"/output/*/; do
  [[ -d "${d}" ]] || continue
  site="$(basename "${d}")"
  [[ -f "${STATUS_DIR}/${site}" ]] && continue
  if [[ -f "${d}/restartout.nc" ]] &&
     [[ $(find "${d}" -maxdepth 1 -name '*.nc' | wc -l) -ge "${MIN_OUTPUT_NC}" ]]; then
    echo "OK" > "${STATUS_DIR}/${site}"
    n_seeded=$((n_seeded + 1))
  fi
done

# A claim with no status belonged to a worker that was interrupted (wall limit,
# node failure). Nothing is running now, so these are stale by definition:
# clear them and the site is retried.
n_swept=0
for c in "${CLAIM_DIR}"/*/; do
  [[ -d "${c}" ]] || continue
  site="$(basename "${c}")"
  if [[ ! -f "${STATUS_DIR}/${site}" ]]; then
    rm -rf "${c}"
    n_swept=$((n_swept + 1))
  fi
done

n_done=$(ls "${STATUS_DIR}" 2>/dev/null | wc -l | tr -d ' ')
n_todo=$((n_sites - n_done))

JOB_SCRIPT="${SLURM_DIR}/ecland_${GROUP}.sbatch"
cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=ecland_${GROUP}
#SBATCH --array=0-$((ARRAY_TASKS - 1))${THROTTLE:+%${THROTTLE}}
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${WORKERS_PER_TASK}
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${SLURM_DIR}/ecland-%A-%a.out

set -u

# Modules for the model run, as ecland_run.sh loads them. python3/3.10.10-01
# rather than python3/new: the two conflict, and the namelist generator only
# needs netCDF4.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load prgenv/intel intel/2021.4 python3/3.10.10-01 hpcx-openmpi/2.9 netcdf4/4.9.1

# NO mpirun here, deliberately. A single point integration is serial, so the
# launcher would add nothing -- and it actively breaks this job shape twice
# over. \`mpirun -np 1\` binds its rank to the first core of the allocation, so N
# independent mpiruns inside one cgroup all land on the SAME core: measured with
# -w 30, all 30 workers sat on CPUs 0/128 at 6.6% each, about 2 cores of work
# from 30 (a 15x loss). It also drains any stdin it inherits. Leaving LAUNCH
# empty makes ecland_run_model.sh exec the binary directly, which is what the
# sibling FLUXNET Shuttle repo does and why -w works there.
export LAUNCH=''
export MEM_PER_CPU='${MEM_PER_CPU}'

# ONE OpenMP thread per worker. This is the single most important line here.
# ecLand is threaded (see -nt in ecland_parse_commandline.sh) and OpenMP defaults
# to every CPU it can see, which is the whole cgroup -- so with -w 30 each of the
# 30 workers spawned 30 spin-waiting threads: 900 threads on 30 CPUs, measured at
# 6.6% CPU per worker, a ~15x loss that wasted 126 CPU-hours before it was found.
# A single point integration gains nothing from threads; the parallelism here is
# one site per worker.
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
# KMP_AFFINITY is the one that actually matters, and it is Intel-specific.
# ecLand is built with the Intel compiler, whose OpenMP runtime pins threads by
# itself and ignores OMP_PROC_BIND: measured with -w 30, every one of the 30
# independent workers claimed core 0, ending up with Cpus_allowed_list=0,128 and
# 7% CPU each -- 30 runnable processes timesharing one core. Each worker here is
# a separate process that must be free to land anywhere in the cgroup, so the
# runtime must not bind at all.
export KMP_AFFINITY=disabled
# And this is the line that fixes -w. ecLand calls MPI_Init even at one point, so
# running the binary directly makes it an OpenMPI SINGLETON -- and a singleton
# still applies OpenMPI's default binding policy, pinning itself to the first
# core of the cgroup. Every worker therefore chose core 0 independently: the
# shells above them held the full 30-CPU mask while each model process narrowed
# itself to Cpus_allowed_list=0,128. Dropping mpirun does not avoid this, because
# the binding comes from the MPI runtime inside the process, not from the
# launcher. Workers must stay unbound so the kernel can spread them.
export OMPI_MCA_hwloc_base_binding_policy=none

# Workers claim sites with an atomic mkdir, so several inside one element are as
# safe as several across nodes. Each needs its own scratch work directory, which
# ecland_run_queue.sh derives from SLURM_ARRAY_TASK_ID -- so give each a distinct
# value rather than patching that script.
for w in \$(seq 0 $((WORKERS_PER_TASK - 1))); do
  SLURM_ARRAY_TASK_ID="\${SLURM_ARRAY_TASK_ID}w\${w}" \\
  "${SCRIPT_DIR}/ecland_run_queue.sh" \\
    -g "${GROUP}" \\
    -Q "${QUEUE}" \\
    -D "${RUN_ROOT}" \\
    -x "${ECLAND_MASTER}" \\
    -t "${FORCING_TYPE}" \\
    -n "${NAMELIST}" \\
    -l "${NLOOP}" &
done
wait
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group        : ${GROUP}"
echo "Runnable     : ${n_sites} sites (forcing ${n_forcing}, physiography ${n_clim})"
echo "Queue        : ${n_todo} to run (${n_done} already done: ${n_seeded} seeded from existing output)"
echo "Claims swept : ${n_swept} (interrupted by a previous run, will be retried)"
echo "Concurrency  : ${ARRAY_TASKS} elements x ${WORKERS_PER_TASK} workers = $((ARRAY_TASKS * WORKERS_PER_TASK)) concurrent sites"
echo "NLOOP        : ${NLOOP}"
echo "Executable   : ${ECLAND_MASTER}"
echo "Namelist     : ${NAMELIST}"
echo "Output       : ${RUN_ROOT}/output"
echo "Job script   : ${JOB_SCRIPT}"
echo

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== dry run, not submitting ==="
  cat "${JOB_SCRIPT}"
  exit 0
fi

sbatch "${JOB_SCRIPT}"
echo
echo "Monitor : squeue -u \$USER -n ecland_${GROUP}"
echo "Progress: ls ${RUN_ROOT}/status | wc -l   (of ${n_sites})"
echo "Tally   : cat ${RUN_ROOT}/status/* | sort | uniq -c"
echo "Retry   : grep -lx FAILED ${RUN_ROOT}/status/* | xargs rm   then submit again"
echo "Postproc: python3 ${SCRIPT_DIR}/postproc_plumber2.py --inputdir ${RUN_ROOT}/output --outdir ${PROJECT_ROOT}/postprocessed"
