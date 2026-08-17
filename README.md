# plumber2-ecland

Scripts and configuration to run [ecLand](https://www.ecmwf.int/en/research/modelling-systems/land-surface) land-surface model simulations over the [PLUMBER2](https://essd.copernicus.org/articles/14/449/2022/) 170 sites.
![PLUMBER2 site locations](plumber2_sites_map.png)

Forcing and evaluation data are the PLUMBER2 v1.0 release: Ukkola, A. M., Abramowitz, G., and De Kauwe, M. G. (2022), *A flux tower dataset tailored for land model evaluation*, Earth Syst. Sci. Data, 14, 449–461, https://doi.org/10.5194/essd-14-449-2022, distributed via the [NCI THREDDS catalogue](https://thredds.nci.org.au/thredds/catalog/ks32/CLEX_Data/PLUMBER2/v1-0/catalog.html).

## Repository layout

```
plumber2-ecland/
├── clim/PLUMBER2/          # Climatology input files (NetCDF, tracked via Git LFS)
├── forcing/PLUMBER2/       # Meteorological forcing, ecLand-ready (NetCDF, tracked via Git LFS)
├── forcing/PLUMBER2_original/  # Raw PLUMBER2 v1.0 Met download — source for forcing/PLUMBER2/
├── flux/PLUMBER2_original/ # Raw PLUMBER2 v1.0 Flux (observed) download — used by the benchmark
├── namelists/              # ecLand namelist configuration files (control + experiment variants)
├── scripts/                # Run, post-processing, download and benchmark scripts
│   ├── all_sites_plumber2.txt       # Complete list of 170 PLUMBER2 sites
│   ├── best_sites_to_benchmark.txt  # Curated list of 42 benchmark sites
│   ├── get_plumber2_forcing.sh      # Download raw Met data from the NCI THREDDS catalogue
│   ├── get_plumber2_flux.sh         # Download raw Flux (observed) data from the NCI THREDDS catalogue
│   ├── regenerate_plumber2_forcing.sh  # Rebuild forcing/PLUMBER2/ from forcing/PLUMBER2_original/
│   ├── run_parallel_local_macos.sh  # Run all/some sites concurrently on a local Mac
│   ├── postproc_plumber2.py         # Post-process raw ecLand output into the PLUMBER2 schema
│   ├── benchmark_plumber2.py        # Score postprocessed output against Flux observations + dashboard
│   ├── dashboard_template.html      # Self-contained dashboard template used by benchmark_plumber2.py
│   └── plot_sites_map.py            # Render plumber2_sites_map.png (site locations, colored by biome)
├── output/                 # Model output — excluded from git
├── postprocessed/          # Post-processed output — excluded from git
└── benchmark/
    ├── models/<model-name>/     # Postprocessed per-experiment output, e.g. ecland_cy50r1,
    │                             # ecland_cy50r1_runoff_fix — excluded from git (regenerable, ~GBs)
    └── dashboards/<model-name>/ # Benchmark metrics/JSON/dashboard per experiment (checked in)
        ├── all170/               # Full 170-site run: metrics.csv, data.json, index.html
        └── best42/               # Same, restricted to the 42 curated benchmark sites
```

## Getting started

Clone the repository with Git LFS support so that the NetCDF pointer files are fetched correctly:

```bash
# Install Git LFS if not already available
# brew install git-lfs
git lfs install
```

```bash
# Clone the repository
git clone git@github.com:gpbalsamo/plumber2-ecland.git
cd plumber2-ecland
```

The `forcing/PLUMBER2/` and `clim/PLUMBER2/` directories contain LFS pointers after cloning.

### Downloading the raw PLUMBER2 data

`forcing/PLUMBER2/` and `flux/PLUMBER2_original/` above are derived from / are direct downloads of the official PLUMBER2 v1.0 release. To (re)fetch them from source instead of relying on Git LFS:

```bash
# Raw meteorological forcing (Met) -> forcing/PLUMBER2_original/
scripts/get_plumber2_forcing.sh

# Raw observed flux (evaluation) data -> flux/PLUMBER2_original/
scripts/get_plumber2_flux.sh

# Rebuild the ecLand-ready forcing/PLUMBER2/ files from forcing/PLUMBER2_original/
scripts/regenerate_plumber2_forcing.sh
```

Both download scripts accept `CATALOG_URL`, `FILESERVER_BASE`, `OUTDIR` and `PATTERN` env var overrides, skip files already present, and resume partial downloads.

## Requirements

- ecLand executable (built separately; see [ECMWF ecLand](https://github.com/ecmwf-ifs/ecland))
- ECMWF HPC environment with the following modules:
  - `prgenv/intel`, `intel/2021.4`
  - `hpcx-openmpi/2.9`, `netcdf4/4.9.1`
  - `python3`
- Python packages: `numpy`, `xarray`, `netCDF4`, `pandas` (for `benchmark_plumber2.py`)
- macOS is also supported for local runs/testing — see [Running locally on macOS](#running-locally-on-macos) below; requires the NCO tools (`ncrename`, `ncks`, `ncatted`, `nccopy`) if regenerating forcing.

## Usage

### 1. Retrieve forcing and clim data

Copy forcing and clim files from git-lfs to your local plumber2-ecland repo:

```bash
scripts/ecland_retrieve_lfs.sh --all
```

### 2. Run experiment and postprocess output

Edit `scripts/run_and_proc_plumber2.sh` to set paths and options to run with your local installation, then:

```bash
bash scripts/run_and_proc_plumber2.sh
```

Note this script runs on an HPC in batch a lower-level script (permitting 25 sites simulations in parallel to speed-up), however it can be run also directly:

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

The postprocessing of model output is done by `scripts/postproc_plumber2.py`, which maps raw ecLand output onto the common PLUMBER2 variable schema (`Qle`, `Qh`, `NEE`, `GPP`, soil moisture/temperature profiles, etc.), including the derived `SWup` and `Rnet` (= `SWnet` + `LWnet`) radiation terms:

```bash
python3 scripts/postproc_plumber2.py \
  --inputdir <output_dir> \
  --outdir <postprocessed_dir>
```

### 3. Check results

To check the postprocessed output run:
```bash
python3 scripts/check_plumber2_dates.py
```

### Running locally on macOS

`scripts/run_parallel_local_macos.sh` fans a run of `ecland_run_experiment.sh` per site out across a bounded worker pool (`xargs -P`), for testing concurrent execution on a single Mac rather than via SLURM:

```bash
scripts/run_parallel_local_macos.sh \
  -j 8 \
  -S scripts/all_sites_plumber2.txt \
  -x <path_to_ecland_executable>
```

`-j` sets the number of concurrent site runs (default 4 — mind available RAM/cores, since each site is a full ecLand process), `-S` an optional site-list file (defaults to all 170), `-x` the ecLand executable. Each site gets an isolated run directory and namelist, so concurrent runs don't share mutable state. Per-site logs and pass/fail status land in `scripts/work/parallel_logs/`.

## Benchmarking

A curated list of 42 recommended benchmark sites (selected by Gab Abramowitz for automated benchmarking) is provided in `scripts/best_sites_to_benchmark.txt`. These sites offer good spatial and biome diversity and are suitable for model evaluation.

To run ecLand only over the benchmark sites:

```bash
scripts/ecland_run_experiment.sh \
  -g PLUMBER2 \
  -t insitu \
  -S scripts/best_sites_to_benchmark.txt \
  -x <path_to_ecland_executable>
```

To post-process and validate only the benchmark sites:

```bash
python3 scripts/postproc_plumber2.py --site $(paste -sd' ' scripts/best_sites_to_benchmark.txt | sed 's/ / --site /g')
python3 scripts/check_plumber2_dates.py
```

### Obs-vs-model benchmark dashboard

`scripts/benchmark_plumber2.py` scores a postprocessed model run against the observed PLUMBER2 v1.0 flux data (`flux/PLUMBER2_original/`, see [Downloading the raw PLUMBER2 data](#downloading-the-raw-plumber2-data)) for `Qle`, `Qh` and `NEE`, using only quality-controlled (measured, non-gapfilled) observation half-hours. For each site it computes bias/RMSE/R/NME plus compact monthly-climatology, seasonal-diurnal and long-term-trend aggregates, then builds a self-contained interactive dashboard (`scripts/dashboard_template.html`) with a pannable/zoomable site map, Taylor diagram, per-biome skill breakdown (fixed 0.0–1.0 NME axis, so different runs are visually comparable), a searchable/sortable ranked table, and a per-site drill-down.

It's model-agnostic: any directory of per-site NetCDF files works as `--model-dir`, whether named in the PLUMBER2-schema convention (`ecLand_PLUMBER2_<site>_<period>.nc`) or a site-only convention with no period in the filename (`*.{SITE}.nc`, e.g. JULES output), and it scores whichever of `Qle`/`Qh`/`NEE` the model actually provides — a model missing a variable (e.g. no `NEE`) just shows that cell as unavailable rather than failing. Time matching is robust to imprecise time encoding (some models store time as float32, which drifts over multi-year records) by reconstructing a clean, uniformly-spaced axis rather than trusting stored timestamps directly.

Convention: keep each model/experiment's postprocessed output under its own `benchmark/models/<model-name>/` directory (e.g. `ecland_cy50r1` for the control run, `ecland_cy50r1_runoff_fix` for a namelist variant, `JULESGL9` for a different model entirely) so multiple runs can be compared side by side.

```bash
# Full 170-site benchmark -> benchmark/dashboards/<model-name>/all170/
python3 scripts/benchmark_plumber2.py \
  --model-dir benchmark/models/<model-name> \
  --out-dir benchmark/dashboards/<model-name>

# Restrict to a curated subset (e.g. the 42 benchmark sites) -> .../best42/
python3 scripts/benchmark_plumber2.py \
  --model-dir benchmark/models/<model-name> \
  --out-dir benchmark/dashboards/<model-name> \
  --sites-file scripts/best_sites_to_benchmark.txt
```

`--out-dir` is a base path: the script automatically routes output into `<out-dir>/all170/` or `<out-dir>/best42/` depending on whether `--sites-file` is given, so the same `--out-dir` works for both commands above. `--flux-dir` overrides the default `flux/PLUMBER2_original/`; `--site` filters to one or more specific sites. Each run writes a metrics CSV, a JSON payload, and `index.html` (named so uploading the output folder to a static host opens the dashboard automatically) — open it directly in a browser, no server required. `benchmark/dashboards/` is checked in with worked examples for the control run, the runoff-fix variant, and JULESGL9.

## Namelist

- `namelists/namelist_ecland_50R1_ctl` — the ecLand 50R1 control configuration (the default used by `ecland_run_experiment.sh` when `-n` is omitted).
- `namelists/namelist_ecland_50R1_runoff_fix` — the control namelist with `&NAMPARSOIL` `RSIGORMIN`/`RSIGORMAX` (surface-runoff orography coefficient bounds) set for the runoff fix, rather than left at their compiled defaults (100.0 / 1000.0). Pass it via `-n namelists/namelist_ecland_50R1_runoff_fix` to `ecland_run_experiment.sh`, or `-n` to `run_parallel_local_macos.sh`.

New namelist variants should follow this naming pattern (`namelist_ecland_50R1_<variant>`) and pair with a matching `benchmark/models/ecland_cy50r1_<variant>/` output directory (see [Benchmarking](#benchmarking)) so runs stay easy to tell apart.

## License

Copyright 2023– ECMWF. Licensed under the [Apache Licence Version 2.0](http://www.apache.org/licenses/LICENSE-2.0).
