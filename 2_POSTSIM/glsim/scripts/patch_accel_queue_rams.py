#!/usr/bin/env python3
from pathlib import Path
import argparse
import re


QUEUE_RAM_BASE_MODULES = (
    "ram_6x8",
    "ram_4x82",
    "ram_4x138",
    "ram_4x161",
    "ram_8x15",
)

TOP_MODULE = "BuckyballAccelerator"
PRIVATE_PREFIX = "glsyn_"


def signal_width(text: str, direction: str, name: str) -> int:
    match = re.search(
        rf"\b{direction}\s+(?:\[(\d+):0\]\s+)?{re.escape(name)}\s*;",
        text,
    )
    if not match:
        raise SystemExit(f"failed to find {direction} {name}")
    return int(match.group(1)) + 1 if match.group(1) is not None else 1


def emit_ram(name: str, raddr_w: int, data_w: int) -> str:
    depth = 1 << raddr_w
    raddr_range = f"[{raddr_w - 1}:0] " if raddr_w > 1 else ""
    data_range = f"[{data_w - 1}:0] " if data_w > 1 else ""
    return f"""module {name} ( R0_addr, R0_en, R0_clk, R0_data, W0_addr, W0_en, W0_clk,
        W0_data );
  input {raddr_range}R0_addr;
  output {data_range}R0_data;
  input {raddr_range}W0_addr;
  input {data_range}W0_data;
  input R0_en, R0_clk, W0_en, W0_clk;

  reg {data_range}Memory[0:{depth - 1}];
  integer _glsim_mem_init_i;

  initial begin
    for (_glsim_mem_init_i = 0; _glsim_mem_init_i < {depth}; _glsim_mem_init_i = _glsim_mem_init_i + 1)
      Memory[_glsim_mem_init_i] = {{{data_w}{{1'b0}}}};
  end

  always @(posedge W0_clk) begin
    if (W0_en)
      Memory[W0_addr] <= W0_data;
  end

  assign R0_data = R0_en ? Memory[R0_addr] : {{{data_w}{{1'bx}}}};
endmodule
"""


def patch_module(text: str, name: str) -> tuple[str, bool]:
    pattern = re.compile(
        rf"(?ms)^module\s+{re.escape(name)}\s*\(.*?^endmodule\s*$"
    )
    match = pattern.search(text)
    if not match:
        return text, False
    module_text = match.group(0)
    raddr_w = signal_width(module_text, "input", "R0_addr")
    waddr_w = signal_width(module_text, "input", "W0_addr")
    data_w = signal_width(module_text, "output", "R0_data")
    wdata_w = signal_width(module_text, "input", "W0_data")
    if raddr_w != waddr_w or data_w != wdata_w:
        raise SystemExit(f"unexpected asymmetric queue RAM ports in {name}")
    return text[: match.start()] + emit_ram(name, raddr_w, data_w) + text[match.end() :], True


def find_queue_ram_modules(text: str) -> list[str]:
    bases = "|".join(re.escape(name) for name in QUEUE_RAM_BASE_MODULES)
    pattern = re.compile(rf"(?m)^module\s+({bases})(?:_\d+)?\b")
    return sorted({match.group(0).split()[1] for match in pattern.finditer(text)})


def find_module_names(text: str) -> list[str]:
    return re.findall(r"(?m)^module\s+([A-Za-z_][A-Za-z0-9_$]*)\b", text)


def privatize_internal_modules(text: str) -> tuple[str, list[str]]:
    module_names = find_module_names(text)
    rename = {
        name: f"{PRIVATE_PREFIX}{name}"
        for name in module_names
        if name != TOP_MODULE and not name.startswith(PRIVATE_PREFIX)
    }
    if not rename:
        return text, []

    # Rename definitions and named module instantiations. This keeps the public
    # accelerator wrapper name stable while preventing gate-netlist internals
    # from overriding same-named RTL modules elsewhere in the mixed simulation.
    alternation = "|".join(re.escape(name) for name in sorted(rename, key=len, reverse=True))
    definition = re.compile(rf"(?m)^module\s+({alternation})\b")
    instance = re.compile(
        rf"(?<![A-Za-z0-9_$])({alternation})(?=\s*(?:#\s*\(|[A-Za-z_\\]))"
    )

    def repl_definition(match: re.Match[str]) -> str:
        name = match.group(1)
        return f"module {rename[name]}"

    def repl_instance(match: re.Match[str]) -> str:
        name = match.group(1)
        return rename[name]

    text = definition.sub(repl_definition, text)
    text = instance.sub(repl_instance, text)
    return text, sorted(rename)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-netlist", required=True)
    parser.add_argument("--out-netlist", required=True)
    args = parser.parse_args()

    src = Path(args.in_netlist)
    text = src.read_text(errors="ignore")
    patched = []
    queue_ram_modules = find_queue_ram_modules(text)
    for name in queue_ram_modules:
        text, changed = patch_module(text, name)
        if changed:
            patched.append(name)

    if not patched:
        print("warning: no queue RAM modules found to patch")

    text, renamed = privatize_internal_modules(text)

    out = Path(args.out_netlist)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(
        f"wrote {out} with patched queue RAMs: {', '.join(patched)}; "
        f"privatized {len(renamed)} internal modules"
    )


if __name__ == "__main__":
    main()
