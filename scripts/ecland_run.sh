#!/bin/bash
# Script to run the ecland model on pre-downloaded forcing and initial conditions.

# To compile:
#module load prgenv/intel intel/2021.4 cmake/3.25 ninja/1.11.1 hpcx-openmpi/2.9 netcdf4/4.9.1 ecbuild/new ecmwf-toolbox/new python3/new
#====== Load modules for intel compiler

module load prgenv/intel intel/2021.4 python3/3.10.10-01
module load hpcx-openmpi/2.9 netcdf4/4.9.1

#====== Setup (change these as required)
GROUP=PLUMBER2
FORCING_TYPE=insitu
INPUT_DIR=/perm/pad/plumber2/
OUTPUT_DIR=/perm/${USER}/${GROUP}/
WORK_DIR=/scratch/${USER}/work_${GROUP}/
NLOOP=2
export LBATCH=true
export PATH=${ecland_ROOT:-/perm/pad/ecland/build}/bin:$PATH
export MEM_PER_CPU='16G'
NAMELIST_FILE="namelist_ecland_50R1_ctl"
eclandExe="/perm/pad/ecland/build/bin/ecland-master-dp"
export LAUNCH='mpirun -np 1'

#===============================================
START=$(date +%s)

ecland-run-experiment -g ${GROUP}\
                      -t ${FORCING_TYPE}\
                      -i ${INPUT_DIR}\
                      -o ${OUTPUT_DIR}\
                      -l ${NLOOP}\
                      -n "/perm/pad/plumber2/namelists/${NAMELIST_FILE}"\
                      -x ${eclandExe}\
                      -w ${WORK_DIR}
                      #-s "CL-002_1997010100-2014123100"\
                      #-n "/home/paga/projects/ecland_opensource/ecland_49r1/namelists/namelist_ecland_49R1_fluxnet_opt"\
END=$(date +%s)
DIFF=$(( $END - $START ))
echo -e "\n\n\t Running ecland-run-experiment on all sites took $DIFF seconds\n"
