"""并行执行 scan.json 中的配置；所有任务成功后发布本轮结果索引。"""

import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from sim.common.scan import fingerprint, read_json, write_json


def execution_plan(scan):
    # 图表设置可以独立调整，不属于仿真输入。
    return {key: scan[key] for key in ("simulator", "jobs")}


def run(scan_path, workers):
    if workers < 1:
        raise ValueError("jobs must be positive")
    scan_path = Path(scan_path).resolve()
    directory = scan_path.parent
    scan = read_json(scan_path)
    binary = (directory / scan["simulator"]).resolve()
    jobs = scan["jobs"]
    configs = [(directory / job["config"]).resolve() for job in jobs]
    results = [(directory / job["result"]).resolve() for job in jobs]
    if not jobs or len(set(results)) != len(results) or set(configs) & set(results):
        raise ValueError("jobs must be nonempty and have unique results separate from configs")
    traces = {(config.parent / read_json(config)["trace"]).resolve() for config in configs}
    sources = {binary, *configs, *traces}
    if set(results) & (sources | {scan_path, directory / "run.json"}):
        raise ValueError("results must not overwrite scan inputs")
    completed = directory / "run.json"
    completed.unlink(missing_ok=True)
    # 缺失轨迹交给同一 C++ 读取器准备，再记录本轮输入；Python 不持有采集规则。
    for trace in sorted(traces):
        if not trace.exists():
            subprocess.run([str(binary), "--generate-trace", str(trace)], cwd=directory, check=True)
    source_hashes = {str(path): fingerprint(path) for path in sorted(sources)}
    timestamps = {path: (path.stat().st_size, path.stat().st_mtime_ns) for path in sources}

    def execute(index):
        config, result = configs[index], results[index]
        log = directory / "logs" / f"{index:04d}.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("w", encoding="utf-8") as output:
            process = subprocess.run([str(binary), str(config), str(result)], cwd=directory,
                                     stdout=output, stderr=subprocess.STDOUT)
            if process.returncode:
                raise RuntimeError(f"job {index:04d} exited {process.returncode}; see {log}")
        data = read_json(result)
        if data["config"] != read_json(config) or not isinstance(data["metrics"], dict):
            raise ValueError(f"result does not match config: {result}")
        return index

    # 先跑一个点，让损坏轨迹和不支持的参数在启动并行任务前报错。
    execute(0)
    print(f"[1/{len(jobs)}] {jobs[0]['config']}")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(execute, index) for index in range(1, len(jobs))]
        for count, future in enumerate(as_completed(futures), 2):
            index = future.result()
            print(f"[{count}/{len(jobs)}] {jobs[index]['config']}")
    for path, stamp in timestamps.items():
        if (path.stat().st_size, path.stat().st_mtime_ns) != stamp:
            raise ValueError(f"input changed during scan: {path}")
    write_json(completed, {"plan": execution_plan(scan), "sources": source_hashes,
                           "results": {job["result"]: fingerprint(path) for job, path in zip(jobs, results)}})
    return completed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scan", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    print(f"completed: {run(args.scan, args.jobs)}")


if __name__ == "__main__":
    main()
