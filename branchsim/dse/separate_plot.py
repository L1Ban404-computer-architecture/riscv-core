"""导出不依赖网络资源的三表预测器交互图。"""

import json
from pathlib import Path


def write_plot(path, rows, provenance):
    payload = json.dumps({"rows": rows, "provenance": provenance}, ensure_ascii=False).replace("<", "\\u003c")
    template = Path(__file__).with_name("separate_plot.html").read_text(encoding="utf-8")
    path.write_text(template.replace("__PAYLOAD__", payload), encoding="utf-8")
