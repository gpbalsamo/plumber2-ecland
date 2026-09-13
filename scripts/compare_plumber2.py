#!/usr/bin/env python3
"""Build a paired comparison dashboard from two benchmark_plumber2.py runs.

Loads plumber2_benchmark_data.json from a control and a "new" dashboard
directory (as written by benchmark_plumber2.py), pairs sites present in
both, and writes a self-contained HTML dashboard with per-variable paired
scatter plots (control vs. new NME, one point per site), an aggregate
metrics table and a sortable/searchable per-site table -- so a namelist or
code change can be compared against a baseline without re-deriving
climatology/diurnal aggregates, which are reused as-is from each input's
own JSON.
"""
import argparse
import json
from pathlib import Path

VARS = ['Qle', 'Qh', 'NEE']
VAR_LABEL = {'Qle': 'Latent heat', 'Qh': 'Sensible heat', 'NEE': 'CO₂ exchange'}
VAR_UNIT = {'Qle': 'W m⁻²', 'Qh': 'W m⁻²', 'NEE': 'µmol m⁻² s⁻¹'}

def load(path):
    d = json.loads(Path(path).read_text())
    by_key = {}
    for s in d['sites']:
        by_key[(s['site'], s['period'])] = s
    return d, by_key

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--control', required=True, type=Path, help='Path to the control dashboard\'s plumber2_benchmark_data.json')
    p.add_argument('--new', required=True, type=Path, help='Path to the new run\'s plumber2_benchmark_data.json')
    p.add_argument('--control-label', required=True, help='Legend label for the control, e.g. "ecLand CY50R1 (control)"')
    p.add_argument('--new-label', required=True, help='Legend label for the new run')
    p.add_argument('--out', required=True, type=Path, help='Output HTML path')
    return p.parse_args()


def main():
    args = parse_args()
    ctrl_doc, ctrl = load(args.control)
    new_doc, new = load(args.new)
    ctrl_label, new_label, out_path = args.control_label, args.new_label, args.out
    keys = sorted(set(ctrl) & set(new))

    rows = []
    for k in keys:
        sc, sn = ctrl[k], new[k]
        row = {
            'site': sc['site'], 'site_name': sc['site_name'], 'country': sc['country'],
            'igbp': sc['igbp'], 'igbp_long': sc['igbp_long'],
            'lat': sc['lat'], 'lon': sc['lon'], 'period': sc['period'], 'years': sc['years'],
            'metrics': {}
        }
        for v in VARS:
            mc, mn = sc['metrics'].get(v), sn['metrics'].get(v)
            if mc is None or mn is None or mc.get('nme') is None or mn.get('nme') is None:
                continue
            row['metrics'][v] = {
                'nme_ctrl': mc['nme'], 'nme_new': mn['nme'],
                'rmse_ctrl': mc['rmse'], 'rmse_new': mn['rmse'],
                'bias_ctrl': mc['bias'], 'bias_new': mn['bias'],
                'r_ctrl': mc['r'], 'r_new': mn['r'],
                'n': mn['n'], 'pct_measured': mn['pct_measured'],
            }
        rows.append(row)

    agg = {}
    for v in VARS:
        vals_c = [r['metrics'][v]['nme_ctrl'] for r in rows if v in r['metrics']]
        vals_n = [r['metrics'][v]['nme_new'] for r in rows if v in r['metrics']]
        rmse_c = [r['metrics'][v]['rmse_ctrl'] for r in rows if v in r['metrics']]
        rmse_n = [r['metrics'][v]['rmse_new'] for r in rows if v in r['metrics']]
        bias_c = [r['metrics'][v]['bias_ctrl'] for r in rows if v in r['metrics']]
        bias_n = [r['metrics'][v]['bias_new'] for r in rows if v in r['metrics']]
        r_c = [r['metrics'][v]['r_ctrl'] for r in rows if v in r['metrics'] and r['metrics'][v]['r_ctrl'] is not None]
        r_n = [r['metrics'][v]['r_new'] for r in rows if v in r['metrics'] and r['metrics'][v]['r_new'] is not None]
        n = len(vals_c)
        agg[v] = {
            'n_sites': n,
            'nme_ctrl': sum(vals_c)/n, 'nme_new': sum(vals_n)/n,
            'rmse_ctrl': sum(rmse_c)/n, 'rmse_new': sum(rmse_n)/n,
            'bias_ctrl': sum(bias_c)/n, 'bias_new': sum(bias_n)/n,
            'r_ctrl': sum(r_c)/len(r_c) if r_c else None, 'r_new': sum(r_n)/len(r_n) if r_n else None,
            'n_improved': sum(1 for c, nn in zip(vals_c, vals_n) if nn < c),
            'n_worsened': sum(1 for c, nn in zip(vals_c, vals_n) if nn > c),
        }

    payload = {
        'ctrl_label': ctrl_label, 'new_label': new_label,
        'ctrl_generated': ctrl_doc.get('generated'), 'new_generated': new_doc.get('generated'),
        'n_sites': len(rows), 'agg': agg, 'sites': rows,
    }

    template = Path(__file__).parent.joinpath('compare_template.html').read_text()
    html = template.replace('__PAYLOAD_JSON__', json.dumps(payload))
    Path(out_path).write_text(html)
    print(f'Wrote {out_path}: {len(rows)} paired sites')

if __name__ == '__main__':
    main()
