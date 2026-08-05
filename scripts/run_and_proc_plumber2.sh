
LBATCH=true ./ecland_run_experiment.sh -g PLUMBER2 -t insitu -x /perm/pad/ecland/build/bin/ecland-master-dp

python3 postproc_plumber2.py \
  --inputdir /perm/pad/plumber2-ecland/output \
  --outdir /perm/pad/plumber2-ecland/postprocessed \
  --overwrite

