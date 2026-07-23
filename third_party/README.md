# Third-party IP

This directory is reserved for external source dependencies. The current core
RTL has no third-party source dependency.

## Policy

- Keep CPU-core RTL in `rtl/core/`.
- Keep external upstream IP under `third_party/ip/`.
- Do not edit third-party IP in place unless the change is intentionally carried
  as a local patch.
- Record every dependency, purpose, license, and pinned commit in this file.
- Add SoC-oriented IP such as APB, AXI, or register generators only if the
  project scope expands beyond the CPU core.

If a dependency is added later, prefer a version-pinned Git submodule and
document its setup here.
