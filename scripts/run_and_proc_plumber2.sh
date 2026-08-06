#!/usr/bin/env bash

LBATCH=true ./ecland_run_experiment.sh -g PLUMBER2 -t insitu -x /perm/${USER}/ecland/build/bin/ecland-master-dp

python3 postproc_plumber2.py \
  --inputdir /perm/${USER}/plumber2-ecland/output \
  --outdir /perm/${USER}/plumber2-ecland/postprocessed \
  --overwrite

