# RTL Coding Style

This document defines the local SystemVerilog coding style for this CPU core.
It follows the spirit of the lowRISC Verilog Coding Style Guide while keeping
the rules focused on this repository.

Reference:

- https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md

## Scope

These rules apply to project-owned RTL under `rtl/`.

Third-party IP under `third_party/ip/` keeps its upstream style. Do not reformat
or rewrite external IP unless the change is intentionally carried as a local
patch and documented.

## Language

- Use SystemVerilog.
- Prefer `.sv` for RTL source files.
- Use `logic` for synthesizable signals.
- Use `always_comb` for combinational logic.
- Use `always_ff` for sequential logic.
- Avoid Verilog `reg` and `wire` in project-owned RTL unless an interface,
  tool limitation, or legacy module requires them.
- Keep synthesizable RTL separate from testbench-only constructs.

## Names

- Use `snake_case` for files, modules, signals, parameters, functions, and
  tasks.
- Use descriptive names over abbreviated names unless the abbreviation is a
  common hardware term.
- Match the primary module name to the file name.
- Use package names ending in `_pkg`.
- Use type names ending in `_t`.
- Use enum values with a short uppercase prefix when it improves readability.

Examples:

```systemverilog
module id_stage;
endmodule

package riscv_core_pkg;
  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB
  } alu_op_e;
endpackage
```

## Ports

- Use `clk_i` for the main clock input.
- Use `rst_ni` for the main active-low reset input.
- Use `_i` suffix for inputs.
- Use `_o` suffix for outputs.
- Use `_io` suffix only for true bidirectional ports.
- Keep port order consistent:
  1. Clock and reset.
  2. Control inputs.
  3. Data inputs.
  4. Control outputs.
  5. Data outputs.

Preferred reset style:

```systemverilog
input logic clk_i,
input logic rst_ni,
```

## Reset

- Use active-low reset for project-owned RTL unless there is a strong local
  reason not to.
- Reset names must end in `_ni` for active-low inputs.
- Keep reset behavior explicit in sequential blocks.
- Prefer one main clock and reset per CPU core module during the initial core
  implementation.

## Sequential Logic

- Use `_q` for registered state and `_d` for next-state values.
- Use `always_ff @(posedge clk_i or negedge rst_ni)` for registers with
  asynchronous active-low reset.
- Put reset assignments first.
- Keep sequential blocks simple: assign registers from their next-state signals
  or from clearly local control logic.

Example:

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    pc_q <= '0;
  end else begin
    pc_q <= pc_d;
  end
end
```

## Combinational Logic

- Use `always_comb`.
- Assign defaults at the top of the block.
- Avoid inferred latches.
- Avoid hidden priority chains unless priority is intentional.
- Use `unique case` when the cases are expected to be mutually exclusive and
  complete.
- Use `priority case` only when priority is intentional.
- Include a `default` case unless the type and tool checks make omission clearly
  safer.

Example:

```systemverilog
always_comb begin
  alu_result_o = '0;

  unique case (alu_op_i)
    ALU_ADD:  alu_result_o = lhs_i + rhs_i;
    ALU_SUB:  alu_result_o = lhs_i - rhs_i;
    default:  alu_result_o = '0;
  endcase
end
```

## Parameters And Constants

- Use `parameter` for module configuration.
- Use `localparam` for internal constants.
- Prefer typed parameters when practical.
- Keep ISA-wide constants, opcode encodings, ALU operation enums, packed
  structs, and shared control types in `rtl/include/riscv_core_pkg.sv`.
- Avoid scattering instruction encodings across pipeline stages.

## Packages

- Import packages explicitly near the top of a module.
- Avoid wildcard imports in deeply shared files when explicit imports are more
  readable.
- Keep `riscv_core_pkg.sv` focused on core-wide definitions.
- Do not use packages to hide module-local implementation details.

Acceptable for small modules:

```systemverilog
import riscv_core_pkg::*;
```

Prefer explicit imports when a module only needs a few names:

```systemverilog
import riscv_core_pkg::alu_op_e;
```

## Structs And Enums

- Use packed structs for pipeline payloads when they make stage boundaries
  clearer.
- Keep pipeline register payload types in the core package until the design
  becomes large enough to justify a dedicated pipeline package.
- Use enums for control selections instead of raw magic constants.
- Size all enum base types explicitly.

Example:

```systemverilog
typedef struct packed {
  logic [31:0] pc;
  logic [31:0] instr;
} if_id_t;
```

## Pipeline Style

- Keep `riscv_core.sv` as a structural top-level for the CPU core.
- Keep stage-local behavior in `rtl/core/pipe/*_stage.sv`.
- Keep reusable execution units in `rtl/core/units/`.
- Keep hazard, stall, flush, and forwarding logic explicit and easy to trace.
- Prefer clear stage payload names over dense bundles of unrelated signals.
- Do not couple the CPU core directly to SoC-level buses.

## Third-party Cells

The project currently vendors PULP `common_cells` as a submodule under
`third_party/ip/common_cells`.

- Instantiate third-party cells only where they reduce real complexity.
- Prefer direct instantiation for simple, stable cells.
- Use thin wrappers when a third-party interface would otherwise leak too much
  into core-owned modules.
- Do not modify third-party source files in place for style consistency.
- Record dependency decisions in `docs/ip-dependencies.md`.

## File Lists And Dependency Tools

For the current project size, maintain source ordering with project file lists.
Bender is not required yet.

Consider adding Bender when:

- More PULP IP dependencies are added.
- Compile ordering becomes costly to maintain by hand.
- Multiple tools need generated source lists from the same dependency graph.
- `common_cells` dependencies must be pulled through its upstream package
  metadata rather than selectively referenced.

If Bender is added later, commit both `Bender.yml` and `Bender.lock`.

## Formatting And Lint

- Use Verible as the preferred formatter and style/lint tool.
- Keep formatting changes separate from functional RTL changes when practical.
- Do not reformat third-party IP.
- Treat lint warnings as design feedback; waive only with a short documented
  reason.
- Add assertions for non-obvious protocol assumptions when the design starts to
  use ready/valid interfaces, pipeline flushes, or hazard forwarding.

## Comments

- Use comments to explain intent, protocol assumptions, and non-obvious design
  choices.
- Avoid comments that merely repeat the code.
- Keep module headers short until interfaces stabilize.
- Prefer self-describing names over large comment blocks.

## Include Files And Macros

- Avoid project-wide macros for normal RTL structure.
- Prefer packages, parameters, enums, and structs over macros.
- Use include files only for vendor-provided headers or carefully documented
  shared definitions.
- Keep macro scope narrow and namespaced if macros are unavoidable.

## Generated Files

- Generated RTL should live outside hand-written core modules.
- Document the generator, input files, and regeneration command near the
  generated output.
- Do not manually edit generated files unless the edit is explicitly temporary
  and clearly marked.

