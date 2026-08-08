#!/usr/bin/env bash

LBATCH=false ./ecland_run_experiment.sh -g PLUMBER2 -t insitu -x /Users/pad/Work/ecland/build/bin/ecland-master-dp

python3 postproc_plumber2.py \
  --inputdir /Users/pad/Work/plumber2-ecland/output \
  --outdir /Users/pad/Work/plumber2-ecland/postprocessed \
  --overwrite

