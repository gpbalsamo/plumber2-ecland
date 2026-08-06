#!/usr/bin/env python3
"""Plot the location of all PLUMBER2 sites on a world map.

Reads lat/lon from surfclim_<SITE>.nc files and saves a PNG map.

Usage
-----
    python3 scripts/plot_sites_map.py
    python3 scripts/plot_sites_map.py --clim-dir /path/to/clim/PLUMBER2 --output map.png
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Plot PLUMBER2 site locations.")
    p.add_argument(
        "--clim-dir",
        type=Path,
        default=Path("/perm/pad/plumber2-ecland/clim/PLUMBER2"),
        help="Directory containing surfclim_<SITE>.nc files.",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=Path("/perm/pad/plumber2-ecland/postprocessed/plumber2_sites_map.png"),
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


def main() -> int:
    args = parse_args()

    clim_dir = args.clim_dir.expanduser().resolve()
    output = args.output.expanduser().resolve()

    if not clim_dir.is_dir():
        print(f"ERROR: clim directory not found: {clim_dir}", file=sys.stderr)
        return 1

    files = sorted(clim_dir.glob("surfclim_*.nc"))
    if not files:
        print(f"ERROR: no surfclim_*.nc files found in {clim_dir}", file=sys.stderr)
        return 1

    print(f"Reading {len(files)} surfclim files...")

    sites, lats, lons = [], [], []
    errors = []
    for f in files:
        site = re.sub(r"^surfclim_", "", f.stem)
        try:
            lat, lon = read_latlon(f)
            sites.append(site)
            lats.append(lat)
            lons.append(lon)
        except Exception as e:
            errors.append(f"  {site}: {e}")

    if errors:
        print("Warnings (could not read lat/lon):")
        for e in errors:
            print(e)

    print(f"Plotting {len(sites)} sites...")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature

        fig = plt.figure(figsize=(18, 9))
        ax = fig.add_subplot(1, 1, 1, projection=ccrs.Robinson())
        ax.set_global()
        ax.add_feature(cfeature.LAND, facecolor="#f0ede8", edgecolor="none")
        ax.add_feature(cfeature.OCEAN, facecolor="#d0e8f5", edgecolor="none")
        ax.add_feature(cfeature.COASTLINE, linewidth=0.5, edgecolor="#888888")
        ax.add_feature(cfeature.BORDERS, linewidth=0.3, edgecolor="#aaaaaa")
        ax.gridlines(linewidth=0.3, color="grey", alpha=0.5, linestyle="--")

        sc = ax.scatter(
            lons, lats,
            transform=ccrs.PlateCarree(),
            s=30, c="#d62728", zorder=5,
            edgecolors="white", linewidths=0.4,
        )

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
            f"PLUMBER2 flux tower sites (n={len(sites)})",
            fontsize=14, pad=10,
        )

    except ImportError:
        # Fallback: plain matplotlib without cartopy
        print("cartopy not available — using plain matplotlib fallback.")
        fig, ax = plt.subplots(figsize=(18, 9))
        ax.set_xlim(-180, 180)
        ax.set_ylim(-90, 90)
        ax.set_xlabel("Longitude")
        ax.set_ylabel("Latitude")
        ax.set_title(f"PLUMBER2 flux tower sites (n={len(sites)})")
        ax.axhline(0, color="grey", linewidth=0.5, linestyle="--")
        ax.axvline(0, color="grey", linewidth=0.5, linestyle="--")
        ax.scatter(lons, lats, s=30, c="#d62728", edgecolors="white",
                   linewidths=0.4, zorder=3)
        if args.label_sites:
            for site, lat, lon in zip(sites, lats, lons):
                ax.text(lon, lat, site.split("_")[0], fontsize=4,
                        ha="left", va="bottom", color="#333333")
        ax.grid(True, linewidth=0.3, alpha=0.5)

    output.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Map saved to: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
