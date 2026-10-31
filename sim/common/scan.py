"""参数生成脚本共用的文件布局；不解释任何模型参数。"""

import argparse
import hashlib
import json
import os
from pathlib import Path


def _reject_constant(value):
    raise ValueError(f"nonfinite JSON number: {value}")


def read_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle, parse_constant=_reject_constant)


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def fingerprint(path):
    path = Path(path)
    before = path.stat()
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError(f"input changed while reading: {path}")
    return {"bytes": after.st_size, "sha256": digest}


def powers_of_two(limit):
    value = 1
    while value <= limit:
        yield value
        value *= 2


def argument_parser(directory, description):
    directory = Path(directory).resolve()
    build = directory.parents[1] / "build/sim"
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--out", type=Path, default=build / directory.name / "scan")
    parser.add_argument("--trace", type=Path, default=build / "shared/runner-insttrace.bin")
    parser.add_argument("--simulator", type=Path, default=build / directory.name / directory.name)
    return parser


def write_scan(args, parameters, plot):
    directory = args.out.resolve()
    jobs = []
    seen = set()
    for point in parameters:
        key = json.dumps(point, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        name = f"{len(jobs):04d}"
        config = f"configs/{name}.json"
        write_json(directory / config, {"trace": str(args.trace.resolve()), "parameters": point})
        jobs.append({"config": config, "result": f"results/{name}.json"})
        plot.setdefault("filters", list(point))
    if not jobs:
        raise ValueError("parameter space is empty")
    manifest = {"simulator": os.path.relpath(args.simulator.resolve(), directory),
                "jobs": jobs, "plot": plot}
    write_json(directory / "scan.json", manifest)
    print(f"generated {len(jobs)} configs: {directory / 'scan.json'}")
