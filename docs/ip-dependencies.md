# IP Dependencies

This project is scoped to a CPU core, not a complete SoC. External IP should
therefore be limited to reusable CPU-core building blocks such as FIFOs,
arbiters, counters, reset synchronizers, and ready/valid pipeline elements.

## Current Dependencies

| Name | Location | Upstream | Pinned commit | License | Purpose |
| --- | --- | --- | --- | --- | --- |
| PULP common_cells | `third_party/ip/common_cells` | https://github.com/pulp-platform/common_cells.git | `63e1b679a70eca3a1d60d686bc1fa170ec08e1ab` | Solderpad Hardware License 0.51 | Reusable core-local primitives such as FIFOs, arbiters, counters, reset synchronizers, CDC blocks, and ready/valid stream registers. |

## Dependency Boundaries

The CPU core may instantiate selected `common_cells` modules directly or through
thin wrappers when doing so improves clarity. The core should not depend on
SoC-level bus fabrics or peripheral-register generators.

Not currently included:

- PULP `axi`: useful for SoC fabrics, caches, DMA, and external memory systems.
- PULP `apb`: useful for low-speed peripherals and register-mapped SoC blocks.
- PULP `register_interface`: useful for generated memory-mapped peripheral
  register blocks.
- OpenTitan `reggen`: useful for SoC peripheral register generation.

These can be added later if the project scope changes.

## Version Management

Dependencies are managed as Git submodules. To update a dependency:

1. Change into the submodule directory.
2. Fetch and checkout the desired upstream tag or commit.
3. Return to the project root.
4. Update this document with the new commit and rationale.
5. Commit the submodule pointer and documentation update together.

