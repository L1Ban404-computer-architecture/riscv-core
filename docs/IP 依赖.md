# IP 依赖

本项目范围限定为 CPU 内核，而非完整的 SoC。因此，外部 IP 应仅限于可复用的 CPU 内核构建模块，例如 FIFO、仲裁器、计数器、复位同步器和 ready/valid 流水线元件。

## 当前依赖

| 名称 | 位置 | 上游 | 固定提交 | 许可证 | 用途 |
| --- | --- | --- | --- | --- | --- |
| PULP common_cells | `third_party/ip/common_cells` | https://github.com/pulp-platform/common_cells.git | `63e1b679a70eca3a1d60d686bc1fa170ec08e1ab` | Solderpad 硬件许可证 0.51 | 可复用的内核本地原语，如 FIFO、仲裁器、计数器、复位同步器、跨时钟域模块以及 ready/valid 流寄存器。 |

## 依赖边界

CPU 内核可直接实例化选定的 `common_cells` 模块，或者当有助于提升清晰度时通过轻量包装器进行实例化。内核不应依赖 SoC 级总线架构或外设寄存器生成器。

当前不包含以下内容：

- PULP `axi`：适用于 SoC 总线架构、缓存、DMA 及外部存储系统。
- PULP `apb`：适用于低速外设及寄存器映射的 SoC 模块。
- PULP `register_interface`：适用于生成的内存映射外设寄存器模块。
- OpenTitan `reggen`：适用于 SoC 外设寄存器生成。

若项目范围发生变化，可后续添加这些依赖。

## 版本管理

依赖项以 Git 子模块的形式进行管理。更新某个依赖的步骤：

1. 进入子模块目录。
2. 获取并检出所需的上游标签或提交。
3. 返回项目根目录。
4. 将新的提交及更新理由记录到本文档中。
5. 将子模块指针与文档更新一并提交。