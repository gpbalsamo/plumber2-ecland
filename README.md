# plumber2-ecland

Scripts and configuration to run [ecLand](https://www.ecmwf.int/en/research/modelling-systems/land-surface) land-surface model simulations over the [PLUMBER2](https://essd.copernicus.org/articles/14/449/2022/) 170 sites, and to score the result against the flux-tower observations.
![PLUMBER2 site locations](plumber2_sites_map.png)

Forcing and evaluation data are the PLUMBER2 v1.0 release: Ukkola, A. M., Abramowitz, G., and De Kauwe, M. G. (2022), *A flux tower dataset tailored for land model evaluation*, Earth Syst. Sci. Data, 14, 449–461, https://doi.org/10.5194/essd-14-449-2022, distributed via the [NCI THREDDS catalogue](https://thredds.nci.org.au/thredds/catalog/ks32/CLEX_Data/PLUMBER2/v1-0/catalog.html).

## Requirements

- An ecLand executable, built separately — see [ECMWF ecLand](https://github.com/ecmwf-ifs/ecland).
- ECMWF HPC modules: `prgenv/intel`, `intel/2021.4`, `hpcx-openmpi/2.9`, `netcdf4/4.9.1`, `python3`.
- Python packages: `numpy`, `xarray`, `netCDF4`, `pandas`.
- Git LFS, to fetch the forcing and climatology NetCDF files.
- macOS works for local runs — see [Running locally on macOS](#running-locally-on-macos). Regenerating forcing there also needs the NCO tools (`ncrename`, `ncks`, `ncatted`, `nccopy`).

## Quick start

Five steps take you from a clone to a scored dashboard. Each step says what to expect when it worked.

### 1. Clone with LFS

```bash
git lfs install
git clone git@github.com:gpbalsamo/plumber2-ecland.git
cd plumber2-ecland
```

*Expect:* `forcing/PLUMBER2/` and `clim/PLUMBER2/` hold LFS pointer files, not yet the data.

### 2. Materialise the input files

```bash
scripts/ecland_retrieve_lfs.sh --all
```

*Expect:* 170 files in `forcing/PLUMBER2/` (`met_insituHT_<site>_<years>.nc`) and 340 in `clim/PLUMBER2/` (`surfclim_*` and `surfinit_*`, one pair per site).

```bash
ls forcing/PLUMBER2 | wc -l    # 170
ls clim/PLUMBER2 | wc -l       # 340
```

### 3. Run ecLand

The main path is **[Running the full 170 sites on the HPC](#running-the-full-170-sites-on-the-hpc)**: mirror the inputs to `$SCRATCH`, submit one SLURM job array of interchangeable workers draining a shared site queue, benchmark there, then copy the results back. Post-processing auto-chains after the array job via a SLURM dependency, so it needs no separate step. Follow that section through and return here for what the outputs mean.

*Expect:* the submit command prints a summary of what will run (sites runnable, queue length, concurrency, output path), a job id, and the monitoring, retry and post-processing commands **for that run**. Each finished site becomes a directory `output/<site>_<years>/` holding the raw `o_*.nc` fields plus the namelist it ran with.

For a handful of sites the mirror is not worth it — `scripts/submit_ecland_slurm.sh -x <exe> -S <site-list>` runs from `$PERM` directly. To skip SLURM entirely, see [One site at a time](#one-site-at-a-time) or [Running locally on macOS](#running-locally-on-macos).

### 4. Post-process

Map the raw ecLand output onto the common PLUMBER2 variable schema (`Qle`, `Qh`, `NEE`, `GPP`, soil moisture and temperature profiles, and the derived `SWup` and `Rnet` = `SWnet` + `LWnet`):

```bash
python3 scripts/postproc_plumber2.py --inputdir output --outdir postprocessed
```

For many sites at once, `scripts/postproc_run_experiment.sh` fans this out over parallel workers instead of the one-site-at-a-time loop above — either as local background processes, or as one SLURM job per site under `LBATCH=true`:

```bash
scripts/postproc_run_experiment.sh -i output -o postprocessed -j 25
LBATCH=true scripts/postproc_run_experiment.sh -i output -o postprocessed -j 25
```

On the full 170-site HPC path below, `submit_ecland_slurm.sh` already runs this for you, chained after the array job — you only need it by hand for a manual or partial re-run.

*Expect:* one file per site in `postprocessed/`, named `ecLand_PLUMBER2_<site>_<years>.nc`. Verify the time axes:

```bash
python3 scripts/check_plumber2_dates.py
```

### 5. Benchmark and open the dashboard

```bash
python3 scripts/benchmark_plumber2.py \
  --model-dir postprocessed \
  --out-dir benchmark/dashboards/<model-name>
```

*Expect:* `benchmark/dashboards/<model-name>/all170/` containing `plumber2_benchmark_metrics.csv`, `plumber2_benchmark_data.json` and `index.html`. Open `index.html` in a browser — it is self-contained, no server needed.

Add `--sites-file scripts/best_sites_to_benchmark.txt` to score only the 42 curated benchmark sites; that writes to `best42/` alongside `all170/`, so the same `--out-dir` serves both.

## Running the full 170 sites on the HPC

To speed up the run using the Lustre filesystem, the files necessary to the run are mirrored on `$SCRATCH` (4863 MB/s vs 530 MB/s on `$PERM`).

Every script below is invoked by its full path, because each takes the tree it
lives in as the tree it works on: the mirror is driven from `$PERM`, and the run
itself from the copy inside `$SCRATCH`.

**1. Mirror inputs and code to `$SCRATCH`.**

```bash
$PERM/plumber2-ecland/scripts/scratch_mirror.sh push
```

*Expect:* `$SCRATCH/plumber2-ecland/` with the same layout as this repository — forcing, clim, flux, namelists, scripts and the ecLand build.

**2. Submit** the mirrored copy of the script, so that forcing is read and output written on Lustre. `-i` puts `output/` inside the mirrored tree. Post-processing auto-chains after the array job finishes, via `--dependency=afterany` — there is no separate post-process step to run by hand.

```bash
cd $SCRATCH/plumber2-ecland
$SCRATCH/plumber2-ecland/scripts/submit_ecland_slurm.sh \
  -i -x $SCRATCH/plumber2-ecland/ecland-build/bin/ecland-master-dp
```

*Expect:* 170 runnable sites, 60 concurrent, and the monitoring commands printed for this run. Completed sites are skipped on resubmission, so retrying failures costs only the failures. Also printed: the id of the chained post-processing job — it starts on its own once every array element reaches a terminal state (success, failure or wall-limit kill alike), processes only the sites `ecland_run_queue.sh` marked `OK`, and writes to `postprocessed/`. Disable the chain with `-P` and run `scripts/postproc_run_experiment.sh` by hand instead; tune its concurrency with `-j` (default 25).

**3. Benchmark** from `$SCRATCH/plumber2-ecland` once the chained post-processing job has finished (`squeue -u $USER -n postproc_PLUMBER2`) — the Python scripts work on the tree you run them from, so this keeps `postprocessed/` on Lustre too. Step 5 of the quick start describes what this produces.

```bash
cd $SCRATCH/plumber2-ecland
python3 $SCRATCH/plumber2-ecland/scripts/benchmark_plumber2.py \
  --model-dir postprocessed --out-dir benchmark/dashboards/<model-name>
```

**4. Copy the results back to `$PERM`.** Back to the `$PERM` copy of the mirror script — the mirrored one would pull `$SCRATCH` onto itself.

```bash
$PERM/plumber2-ecland/scripts/scratch_mirror.sh pull
```

*Expect:* `postprocessed/` and `benchmark/{models,dashboards}` return; raw `output/` stays behind. **`$SCRATCH` is pruned automatically**, so anything not pulled back is eventually lost. `$PERM/plumber2-ecland/scripts/scratch_mirror.sh status` shows both sides.

### What a full run costs

At the defaults (`-a 2 -w 30 -l 2 -T 02:30:00 -q nf -M 2G`: 60 concurrent sites from 2 SLURM job slots, 2 spin-up loops):

| | |
|---|---|
| Wall clock | **69 min** |
| CPU time | **63 CPU-hours** |
| Raw output | **131 GB** (~770 MB per site) |
| Cost | **14.0 ms per forcing timestep** |

Cost scales with timesteps rather than years, since PLUMBER2 mixes half-hourly and hourly forcing; estimate a new group from `len(time)` in its forcing files. `-d` prints the job script without submitting and `-h` lists every option; the header of `scripts/submit_ecland_slurm.sh` explains how to choose concurrency and why 60 workers is the point where it stops paying.

## Other ways to run

### One site at a time

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

Add `-S scripts/best_sites_to_benchmark.txt` to restrict it to a site list. `scripts/run_and_proc_plumber2.sh` wraps this in a run-then-post-process sequence: edit the paths at its top, then `bash scripts/run_and_proc_plumber2.sh`.

### Running locally on macOS

`scripts/run_parallel_local_macos.sh` fans one `ecland_run_experiment.sh` per site across a bounded worker pool (`xargs -P`):

```bash
scripts/run_parallel_local_macos.sh \
  -j 8 \
  -S scripts/all_sites_plumber2.txt \
  -x <path_to_ecland_executable>
```

`-j` is the number of concurrent sites (default 4 — each is a full ecLand process, so mind RAM and cores), `-S` a site list (default: all 170), `-x` the executable. Each site gets an isolated run directory and namelist. Per-site logs and pass/fail status land in `scripts/work/parallel_logs/`.

### Re-fetching the raw PLUMBER2 data

`forcing/PLUMBER2/` and `flux/PLUMBER2_original/` come from the official v1.0 release. To fetch from source instead of Git LFS:

```bash
scripts/get_plumber2_forcing.sh          # raw Met   -> forcing/PLUMBER2_original/
scripts/get_plumber2_flux.sh             # raw Flux  -> flux/PLUMBER2_original/
scripts/regenerate_plumber2_forcing.sh   # ecLand-ready forcing/PLUMBER2/
```

Both download scripts accept `CATALOG_URL`, `FILESERVER_BASE`, `OUTDIR` and `PATTERN` overrides, skip files already present, and resume partial downloads.

## The benchmark dashboard

`scripts/benchmark_plumber2.py` scores a post-processed run against the observed PLUMBER2 v1.0 flux data (`flux/PLUMBER2_original/`) for `Qle`, `Qh` and `NEE`, using **only quality-controlled, non-gapfilled observation half-hours**. Per site it computes bias, RMSE, R and NME plus monthly-climatology, seasonal-diurnal and long-term-trend aggregates, then builds a self-contained dashboard from `scripts/dashboard_template.html`: a pannable site map, a Taylor diagram, a per-biome skill breakdown on a fixed 0.0–1.0 NME axis (so runs are visually comparable), a sortable ranked table and a per-site drill-down.

It is model-agnostic. Any directory of per-site NetCDF files works as `--model-dir`, whether named in the PLUMBER2 convention (`ecLand_PLUMBER2_<site>_<period>.nc`) or a site-only one (`*.{SITE}.nc`, e.g. JULES), and it scores whichever of `Qle`/`Qh`/`NEE` the model provides — a missing variable shows as unavailable rather than failing. Time matching tolerates imprecise encoding (float32 time drifts over multi-year records) by reconstructing a uniform axis rather than trusting stored timestamps.

Keep each experiment's post-processed output under its own `benchmark/models/<model-name>/` — `ecland_cy50r1` for the control, `ecland_cy50r1_runoff_fix` for a namelist variant, `JULESGL9` for another model entirely — so runs can be compared side by side. `benchmark/dashboards/` is checked in with worked examples for all three.

**Exporting figures.** Every panel carries `PNG` / `SVG` / `PDF` buttons: `PNG` gives a 2400 px raster (300 dpi at 20 cm wide), `SVG` a vector file for Inkscape or Illustrator, `PDF` opens the print dialog for that one figure (choose *Save as PDF*). Each export carries its own title, the selected variable, the legend and a provenance line, and is always drawn on white even when the dashboard is in dark mode. The four seasonal diurnal panels export together as one 2×2 figure.

**After editing the template**, re-render the checked-in dashboards without recomputing any metric:

```bash
python3 scripts/benchmark_plumber2.py --rebuild-html benchmark/dashboards
```

Other options: `--flux-dir` overrides the observation directory, `--site` filters to one or more sites (repeatable), `--out-dir` is a base path that the script routes into `all170/` or `best42/` itself.

## Namelists

- `namelists/namelist_ecland_50R1_ctl` — the ecLand 50R1 control, used by `ecland_run_experiment.sh` when `-n` is omitted.
- `namelists/namelist_ecland_50R1_runoff_fix` — the control with `&NAMPARSOIL` `RSIGORMIN`/`RSIGORMAX` (surface-runoff orography bounds) set for the runoff fix rather than left at their compiled defaults (100.0 / 1000.0).

Name new variants `namelist_ecland_50R1_<variant>` and pair each with a matching `benchmark/models/ecland_cy50r1_<variant>/` output directory, so runs stay easy to tell apart.

## Repository layout

```
plumber2-ecland/
├── clim/PLUMBER2/              # Climatology input (NetCDF, Git LFS)
├── forcing/PLUMBER2/           # ecLand-ready meteorological forcing (NetCDF, Git LFS)
├── forcing/PLUMBER2_original/  # Raw PLUMBER2 v1.0 Met download
├── flux/PLUMBER2_original/     # Raw PLUMBER2 v1.0 Flux (observed) — used by the benchmark
├── namelists/                  # ecLand namelist configurations
├── scripts/                    # Run, post-processing, download and benchmark scripts
├── output/                     # Raw model output — not in git
├── postprocessed/              # Post-processed output — not in git
└── benchmark/
    ├── models/<model-name>/    # Post-processed output per experiment — not in git (regenerable)
    └── dashboards/<model-name>/  # Metrics, JSON and dashboard per experiment (checked in)
        ├── all170/             # Full 170-site run
        └── best42/             # The 42 curated benchmark sites
```

Key scripts. The shell scripts resolve the repository root from their own location, so they run from any directory; the Python ones default to paths relative to the working directory, so run them from the repository root (or from the `$SCRATCH` mirror, which has the same layout).

| Script | Does |
|---|---|
| `ecland_retrieve_lfs.sh` | Materialise forcing and clim from Git LFS |
| `get_plumber2_forcing.sh`, `get_plumber2_flux.sh` | Download raw Met / Flux from NCI THREDDS |
| `regenerate_plumber2_forcing.sh` | Rebuild `forcing/PLUMBER2/` from the raw Met download |
| `submit_ecland_slurm.sh` | Run a site group as one SLURM job array (the fast path) |
| `ecland_run_experiment.sh` | Run sites directly, without SLURM |
| `run_parallel_local_macos.sh` | Run sites concurrently on a local Mac |
| `scratch_mirror.sh` | `push` / `pull` / `status` between `$PERM` and `$SCRATCH` |
| `postproc_plumber2.py` | Raw ecLand output → PLUMBER2 variable schema |
| `check_plumber2_dates.py` | Check the post-processed time axes |
| `benchmark_plumber2.py` | Score against observations, build the dashboard |
| `plot_sites_map.py` | Render `plumber2_sites_map.png` |

Site lists: `scripts/all_sites_plumber2.txt` (all 170) and `scripts/best_sites_to_benchmark.txt` (the 42 recommended by Gab Abramowitz for automated benchmarking, chosen for spatial and biome diversity).

## License

Copyright 2023– ECMWF. Licensed under the [Apache Licence Version 2.0](http://www.apache.org/licenses/LICENSE-2.0).
