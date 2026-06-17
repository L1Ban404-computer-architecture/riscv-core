# Third-party IP

This directory contains external source dependencies that are version-pinned by
Git submodules.

## Layout

```text
third_party/
  ip/
    common_cells/
```

## Policy

- Keep CPU-core RTL in `rtl/core/`.
- Keep external upstream IP under `third_party/ip/`.
- Do not edit third-party IP in place unless the change is intentionally carried
  as a local patch.
- Record every dependency, purpose, license, and pinned commit in
  `docs/ip-dependencies.md`.
- Add SoC-oriented IP such as APB, AXI, or register generators only if the
  project scope expands beyond the CPU core.

## Setup

After cloning this repository, initialize external IP with:

```sh
git submodule update --init --recursive
```

