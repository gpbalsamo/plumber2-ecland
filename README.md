# plumber2-ecland

Scripts and configuration to run [ecLand](https://www.ecmwf.int/en/research/modelling-systems/land-surface) land-surface model simulations over the [PLUMBER2](https://gmd.copernicus.org/articles/15/5511/2022/) benchmark sites.

## Repository layout

```
plumber2-ecland/
├── clim/PLUMBER2/          # Climatology input files (NetCDF, tracked via Git LFS)
├── forcing/PLUMBER2/       # Meteorological forcing files (NetCDF, tracked via Git LFS)
├── namelists/              # ecLand namelist configuration files
├── scripts/                # Run, post-processing and validation scripts
├── output/                 # Model output — excluded from git
└── postprocessed/          # Post-processed output — excluded from git
```

## Requirements

- ecLand executable (built separately; see [ECMWF ecLand documentation](https://confluence.ecmwf.int/display/ECLAND))
- ECMWF HPC environment with the following modules:
  - `prgenv/intel`, `intel/2021.4`
  - `hpcx-openmpi/2.9`, `netcdf4/4.9.1`
  - `python3`
- Python packages: `numpy`, `xarray`, `netCDF4`

## Usage

### 1. Retrieve forcing data

```bash
scripts/ecland_retrieve.sh <file_path> [target_path]
```

### 2. Run experiments

Edit `scripts/ecland_run.sh` to set paths and options, then:

```bash
bash scripts/ecland_run.sh
```

Or use the lower-level script directly:

```bash
scripts/ecland_run_experiment.sh \
  -g PLUMBER2 \
  -t insitu \
  -i <input_dir> \
  -o <output_dir> \
  -n namelists/namelist_ecland_50R1_ctl \
  -x <path_to_ecland_executable> \
  -w <work_dir>
```

### 3. Post-process output

```bash
python3 scripts/postproc_plumber2.py \
  --input-dir <output_dir> \
  --output-dir <postprocessed_dir>
```

### 4. Validate results

```bash
scripts/ecland_validate.sh
python3 scripts/ecland_validate_stats.py
```

## Namelist

The default namelist `namelists/namelist_ecland_50R1_ctl` corresponds to the ecLand 50R1 control configuration.

## License

Copyright 2023– ECMWF. Licensed under the [Apache Licence Version 2.0](http://www.apache.org/licenses/LICENSE-2.0).
