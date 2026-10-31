"""读取原始 JSON 配置和结果，生成模型无关、可离线打开的交互散点图。"""

import argparse
import csv
import json
from pathlib import Path

from sim.common.run import execution_plan
from sim.common.scan import fingerprint, read_json

COMMON = Path(__file__).parent


def load_rows(scan_path):
    scan_path = Path(scan_path).resolve()
    directory = scan_path.parent
    scan = read_json(scan_path)
    completed = read_json(directory / "run.json")
    if completed["plan"] != execution_plan(scan):
        raise ValueError("scan plan changed; rerun the scan")
    for source, saved in completed["sources"].items():
        if fingerprint(source) != saved:
            raise ValueError(f"input changed: {source}; rerun the scan")
    rows = []
    for job in scan["jobs"]:
        config = read_json(directory / job["config"])
        result_path = directory / job["result"]
        if fingerprint(result_path) != completed["results"][job["result"]]:
            raise ValueError(f"result changed: {result_path}; rerun the scan")
        result = read_json(result_path)
        if result["config"] != config:
            raise ValueError(f"config/result mismatch: {result_path}")
        parameters, metrics = config["parameters"], result["metrics"]
        if parameters.keys() & metrics.keys() or "id" in parameters or "id" in metrics:
            raise ValueError(f"parameter/metric field collision: {result_path}")
        rows.append({"id": Path(job["config"]).stem, **parameters, **metrics})
    return scan["plot"], rows


def write_report(path, settings, rows):
    path = Path(path)
    fields = list(dict.fromkeys(key for row in rows for key in row))
    for key in ("x", "y", "color", "shape"):
        if settings[key] not in fields:
            raise ValueError(f"unknown plot field: {settings[key]}")
    payload = json.dumps({"plot": settings, "fields": fields, "rows": rows},
                         ensure_ascii=False, allow_nan=False).replace("<", "\\u003c")
    page = (COMMON / "plot.html").read_text(encoding="utf-8")
    page = page.replace("__DATA__", payload).replace("__SCRIPT__", (COMMON / "plot.js").read_text(encoding="utf-8"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(page, encoding="utf-8")
    with path.with_suffix(".csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scan", type=Path)
    parser.add_argument("--out", type=Path, help="默认写入 scan.json 同目录的 report.html")
    args = parser.parse_args(argv)
    settings, rows = load_rows(args.scan)
    output = args.out or args.scan.parent / "report.html"
    write_report(output, settings, rows)
    csv_path = output.with_suffix(".csv")
    print(f"report: {output}; table: {csv_path}")


if __name__ == "__main__":
    main()
