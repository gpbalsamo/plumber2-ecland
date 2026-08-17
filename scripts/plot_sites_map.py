#!/usr/bin/env python3
"""Plot the location of all PLUMBER2 sites on a world map, colored by biome.

Reads lat/lon from surfclim_<SITE>.nc files and the IGBP vegetation class
from the matching flux/PLUMBER2_original/<SITE>_*.nc file, then saves a PNG
map with sites colored by one of three broad biome groups (Forest,
Shrubland & Savanna, Grass/Crop/Wetland) with the specific IGBP class within
each group shown via marker shape, and a legend spelling out all 11 classes.

The three-group color split (rather than one color per IGBP class) is
deliberate: validated against the dataviz skill's CVD-safety checks in an
all-pairs (map/scatter) context, this palette's categorical hues only clear
every check for the first three slots -- more colors would mean some pairs
of biomes become hard to tell apart for colorblind readers. Marker shape is
a secondary encoding layered on top of color (never a replacement for it)
to carry the finer-grained class within each group without spending more of
the color channel than it can safely give.

Usage
-----
    python3 scripts/plot_sites_map.py
    python3 scripts/plot_sites_map.py --clim-dir clim/PLUMBER2 --flux-dir flux/PLUMBER2_original --output map.png
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import numpy as np

# Validated categorical palette (light mode), first 3 slots -- the only
# subset of the documented 8-hue set that clears every CVD/normal-vision
# check under all-pairs comparison (see dataviz skill, references/palette.md
# and references/color-formula.md). Order/hues must not be changed without
# re-running the validator.
GROUP_COLORS = {
    "Forest": "#2a78d6",
    "Shrubland & Savanna": "#eb6834",
    "Grass, Crop & Wetland": "#1baf7a",
}

# Marker shapes, assigned by position within each group below -- at most 4
# classes per group, so 4 maximally-distinct shapes cover every case.
GROUP_MARKERS = ["o", "s", "^", "D"]

# IGBP short code -> (group, long name). Order within each group fixes which
# marker shape (GROUP_MARKERS, by position) that class gets.
IGBP_TO_GROUP = {
    "ENF": ("Forest", "Evergreen Needleleaf Forest"),
    "EBF": ("Forest", "Evergreen Broadleaf Forest"),
    "DBF": ("Forest", "Deciduous Broadleaf Forest"),
    "MF":  ("Forest", "Mixed Forest"),
    "OSH": ("Shrubland & Savanna", "Open Shrubland"),
    "CSH": ("Shrubland & Savanna", "Closed Shrubland"),
    "SAV": ("Shrubland & Savanna", "Savanna"),
    "WSA": ("Shrubland & Savanna", "Woody Savanna"),
    "GRA": ("Grass, Crop & Wetland", "Grassland"),
    "CRO": ("Grass, Crop & Wetland", "Cropland"),
    "WET": ("Grass, Crop & Wetland", "Permanent Wetland"),
}


def _build_igbp_markers() -> dict[str, str]:
    """Assign each IGBP code a marker shape by its position within its group."""
    order_in_group: dict[str, int] = {}
    markers: dict[str, str] = {}
    for code, (group, _name) in IGBP_TO_GROUP.items():
        idx = order_in_group.get(group, 0)
        markers[code] = GROUP_MARKERS[idx % len(GROUP_MARKERS)]
        order_in_group[group] = idx + 1
    return markers


IGBP_TO_MARKER = _build_igbp_markers()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Plot PLUMBER2 site locations, colored by biome.")
    p.add_argument(
        "--clim-dir",
        type=Path,
        default=Path("clim/PLUMBER2"),
        help="Directory containing surfclim_<SITE>.nc files.",
    )
    p.add_argument(
        "--flux-dir",
        type=Path,
        default=Path("flux/PLUMBER2_original"),
        help="Directory containing raw PLUMBER2 Flux files (source of IGBP_veg_short).",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=Path("plumber2_sites_map.png"),
        help="Output PNG path.",
    )
    p.add_argument(
        "--label-sites", action="store_true",
        help="Add site name labels to the map (can be crowded with 170 sites).",
    )
    return p.parse_args()


def read_latlon(path: Path) -> tuple[float, float]:
    """Return (lat, lon) from a surfclim NetCDF file."""
    try:
        import xarray as xr
        ds = xr.open_dataset(path)
        for lat_name in ("lat", "latitude", "nav_lat", "station_latitude"):
            for lon_name in ("lon", "longitude", "nav_lon", "station_longitude"):
                if lat_name in ds and lon_name in ds:
                    lat = float(np.asarray(ds[lat_name].values).flat[0])
                    lon = float(np.asarray(ds[lon_name].values).flat[0])
                    ds.close()
                    return lat, lon
        ds.close()
    except Exception:
        pass

    # Fallback: netCDF4
    from netCDF4 import Dataset
    with Dataset(path) as ds:
        for lat_name in ("lat", "latitude", "nav_lat", "station_latitude"):
            for lon_name in ("lon", "longitude", "nav_lon", "station_longitude"):
                if lat_name in ds.variables and lon_name in ds.variables:
                    lat = float(np.asarray(ds.variables[lat_name][:]).flat[0])
                    lon = float(np.asarray(ds.variables[lon_name][:]).flat[0])
                    return lat, lon

    raise KeyError(f"No lat/lon variables found in {path}")


def read_igbp(path: Path) -> str:
    """Return the IGBP short vegetation code from a raw PLUMBER2 Flux file."""
    from netCDF4 import Dataset
    with Dataset(path) as ds:
        raw = ds.variables["IGBP_veg_short"][...]
        return raw.tobytes().decode(errors="ignore").strip("\x00").strip()


def build_flux_index(flux_dir: Path) -> dict[str, Path]:
    """Map site code -> its raw Flux file path."""
    index: dict[str, Path] = {}
    for f in sorted(flux_dir.glob("*.nc")):
        m = re.match(r"([A-Za-z0-9\-]+)_", f.name)
        if m:
            index[m.group(1)] = f
    return index


def main() -> int:
    args = parse_args()

    clim_dir = args.clim_dir.expanduser().resolve()
    flux_dir = args.flux_dir.expanduser().resolve()
    output = args.output.expanduser().resolve()

    if not clim_dir.is_dir():
        print(f"ERROR: clim directory not found: {clim_dir}", file=sys.stderr)
        return 1
    if not flux_dir.is_dir():
        print(f"ERROR: flux directory not found: {flux_dir}", file=sys.stderr)
        return 1

    files = sorted(clim_dir.glob("surfclim_*.nc"))
    if not files:
        print(f"ERROR: no surfclim_*.nc files found in {clim_dir}", file=sys.stderr)
        return 1

    print(f"Reading {len(files)} surfclim files...")
    flux_index = build_flux_index(flux_dir)

    sites, lats, lons, groups, igbp_codes = [], [], [], [], []
    errors = []
    igbp_seen: dict[str, str] = {}  # code -> long name, for the legend
    for f in files:
        site_full = re.sub(r"^surfclim_", "", f.stem)
        site_code = site_full.split("_")[0]
        try:
            lat, lon = read_latlon(f)
        except Exception as e:
            errors.append(f"  {site_full}: {e}")
            continue

        igbp = None
        flux_path = flux_index.get(site_code)
        if flux_path is not None:
            try:
                igbp = read_igbp(flux_path)
            except Exception as e:
                errors.append(f"  {site_full}: could not read IGBP class: {e}")

        group, long_name = IGBP_TO_GROUP.get(igbp, (None, None))
        if group is None:
            errors.append(f"  {site_full}: unrecognised/missing IGBP class {igbp!r}; excluded from biome coloring")
            continue

        sites.append(site_full)
        lats.append(lat)
        lons.append(lon)
        groups.append(group)
        igbp_codes.append(igbp)
        igbp_seen[igbp] = long_name

    if errors:
        print("Warnings:")
        for e in errors:
            print(e)

    print(f"Plotting {len(sites)} sites across {len(igbp_seen)} IGBP classes...")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D

    # One (color, marker) combination per IGBP class actually present, grouped
    # by biome group for plotting and for the legend. Also count sites per
    # class (and per group) for the legend labels.
    classes_by_group: dict[str, list[str]] = {}
    class_counts: dict[str, int] = {}
    for code, group in zip(igbp_codes, groups):
        classes_by_group.setdefault(group, [])
        if code not in classes_by_group[group]:
            classes_by_group[group].append(code)
        class_counts[code] = class_counts.get(code, 0) + 1
    for group in classes_by_group:
        classes_by_group[group].sort(key=lambda c: GROUP_MARKERS.index(IGBP_TO_MARKER[c]))

    # Legend: a heading per group (color swatch, bolded after legend
    # creation below), followed by one real marker+color entry per class in it.
    legend_handles: list[Line2D] = []
    header_indices: list[int] = []
    for group_name, color in GROUP_COLORS.items():
        codes_in_group = classes_by_group.get(group_name, [])
        if not codes_in_group:
            continue
        group_n = sum(class_counts[c] for c in codes_in_group)
        header_indices.append(len(legend_handles))
        legend_handles.append(Line2D(
            [0], [0], marker="none", linestyle="none",
            label=f"{group_name} ({group_n})",
        ))
        for code in codes_in_group:
            legend_handles.append(Line2D(
                [0], [0], marker=IGBP_TO_MARKER[code], linestyle="none", markersize=7,
                markerfacecolor=color, markeredgecolor="white", markeredgewidth=0.7,
                label=f"    {code} — {igbp_seen[code]} ({class_counts[code]})",
            ))

    def style_legend(leg):
        leg.get_frame().set_facecolor("#fcfcfb")
        texts = leg.get_texts()
        for i in header_indices:
            texts[i].set_fontweight("bold")

    def scatter_by_class(ax, **scatter_kwargs):
        """Issue one scatter() call per (color, marker) class -- matplotlib
        can't vary marker shape within a single scatter() call."""
        lons_arr, lats_arr = np.asarray(lons), np.asarray(lats)
        codes_arr = np.asarray(igbp_codes)
        for group_name, color in GROUP_COLORS.items():
            for code in classes_by_group.get(group_name, []):
                sel = codes_arr == code
                ax.scatter(
                    lons_arr[sel], lats_arr[sel],
                    s=32, c=color, marker=IGBP_TO_MARKER[code], zorder=5,
                    edgecolors="white", linewidths=0.5,
                    **scatter_kwargs,
                )

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature

        fig = plt.figure(figsize=(18, 10))
        ax = fig.add_subplot(1, 1, 1, projection=ccrs.Robinson())
        ax.set_global()
        ax.add_feature(cfeature.LAND, facecolor="#f0ede8", edgecolor="none")
        ax.add_feature(cfeature.OCEAN, facecolor="#d0e8f5", edgecolor="none")
        ax.add_feature(cfeature.COASTLINE, linewidth=0.5, edgecolor="#888888")
        ax.add_feature(cfeature.BORDERS, linewidth=0.3, edgecolor="#aaaaaa")
        ax.gridlines(linewidth=0.3, color="grey", alpha=0.5, linestyle="--")

        scatter_by_class(ax, transform=ccrs.PlateCarree())

        if args.label_sites:
            for site, lat, lon in zip(sites, lats, lons):
                label = site.split("_")[0]  # strip year range
                ax.text(
                    lon, lat, label,
                    transform=ccrs.PlateCarree(),
                    fontsize=4, ha="left", va="bottom",
                    color="#333333", zorder=6,
                )

        ax.set_title(
            f"PLUMBER2 flux tower sites (n={len(sites)}), colored by biome",
            fontsize=14, pad=10,
        )
        leg = ax.legend(
            handles=legend_handles, loc="lower left", fontsize=7.5,
            frameon=True, framealpha=0.92, edgecolor="#c3c2b7",
            labelspacing=0.55, handletextpad=0.8, borderpad=0.9,
        )
        style_legend(leg)

    except ImportError:
        # Fallback: plain matplotlib without cartopy
        print("cartopy not available — using plain matplotlib fallback.")
        fig, ax = plt.subplots(figsize=(18, 10))
        ax.set_xlim(-180, 180)
        ax.set_ylim(-90, 90)
        ax.set_xlabel("Longitude")
        ax.set_ylabel("Latitude")
        ax.set_title(f"PLUMBER2 flux tower sites (n={len(sites)}), colored by biome")
        ax.axhline(0, color="grey", linewidth=0.5, linestyle="--")
        ax.axvline(0, color="grey", linewidth=0.5, linestyle="--")
        scatter_by_class(ax)
        if args.label_sites:
            for site, lat, lon in zip(sites, lats, lons):
                ax.text(lon, lat, site.split("_")[0], fontsize=4,
                        ha="left", va="bottom", color="#333333")
        ax.grid(True, linewidth=0.3, alpha=0.5)
        leg = ax.legend(
            handles=legend_handles, loc="lower left", fontsize=7.5,
            frameon=True, framealpha=0.92, edgecolor="#c3c2b7",
            labelspacing=0.55, handletextpad=0.8, borderpad=0.9,
        )
        style_legend(leg)

    output.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Map saved to: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
