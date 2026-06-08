#!/usr/bin/env python3
from pathlib import Path
import argparse
import re


QUEUE_RAM_MODULES = {
    "ram_4x82",
    "ram_4x161",
    "ram_8x15_0",
    "ram_8x15_1",
    "ram_8x15_2",
}


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-netlist", required=True)
    parser.add_argument("--out-netlist", required=True)
    args = parser.parse_args()

    src = Path(args.in_netlist)
    text = src.read_text(errors="ignore")
    patched = []
    for name in sorted(QUEUE_RAM_MODULES):
        text, changed = patch_module(text, name)
        if changed:
            patched.append(name)

    missing = QUEUE_RAM_MODULES - set(patched)
    if missing:
        raise SystemExit(f"missing queue RAM modules: {', '.join(sorted(missing))}")

    out = Path(args.out_netlist)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {out} with patched queue RAMs: {', '.join(patched)}")


if __name__ == "__main__":
    main()
