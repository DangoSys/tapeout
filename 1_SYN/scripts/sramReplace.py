#!/usr/bin/env python3
"""Generate DC-facing SRAM replacement RTL and filelist.

The real SRAM compiler flow writes manifests under 0_RTL/real_sram_libs.
This script consumes those manifests and emits:
  * 0_RTL/generated/sram_replacements.sv
  * 0_RTL/generated/synthesis_stubs.sv
  * config/rtl.f

Supported SRAM modules are replaced by thin wrappers around the physical
compiler macros. Unsupported multi-port memories remain in the RTL filelist.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = Path(os.environ.get("RTL_STAGE_DIR", REPO_ROOT / os.environ.get("RTL_STAGE_DIR_NAME", "0_RTL")))
RTL_SOURCE_DIRS = (
    RTL_DIR,
    RTL_DIR / "RTL",
)
REAL_SRAM_DIR = RTL_DIR / "real_sram_libs"
DEFAULT_MANIFEST = REAL_SRAM_DIR / "macro_manifest.csv"
DEFAULT_RTL_MANIFEST = REAL_SRAM_DIR / "rtl_sram_manifest.csv"
GENERATED_RTL_DIR = RTL_DIR / "generated"
DEFAULT_OUT = GENERATED_RTL_DIR / "sram_replacements.sv"
DEFAULT_FILELIST = REPO_ROOT / "config" / "rtl.f"
SOURCE_FILELIST = RTL_DIR / "RTL" / "filelist.f"
SYNTHESIS_STUBS = GENERATED_RTL_DIR / "synthesis_stubs.sv"

SYNTHESIS_EXCLUDED_MODULES = {
    "BackdoorGetReadAddrDPI",
    "BackdoorGetWriteAddrDPI",
    "BackdoorGetWriteDataDPI",
    "BackdoorPutReadDataDPI",
    "BackdoorPutWriteDoneDPI",
    "BBSimDRAM",
    "BdbClkDPI",
    "CTraceDPI",
    "ClockSourceAtFreqMHz",
    "ITraceDPI",
    "MTraceDPI",
    "MemPMCTraceDPI",
    "PMCTraceDPI",
    "SCUReadDPI",
    "SCUWriteDPI",
    "SimDRAM",
    "SimJTAG",
}

SYNTHESIS_STUBS_TEXT = """// Synthesis-only definitions for simulation/DPI black boxes.
// Keep behavior out of these modules; they only make DC linking deterministic.

module ITraceDPI(
  input [7:0] is_issue,
  input [31:0] rob_id,
  input [31:0] domain_id,
  input [31:0] funct,
  input [63:0] pc,
  input [63:0] rs1,
  input [63:0] rs2,
  input [7:0] bank_enable,
  input enable
);
endmodule

module MTraceDPI(
  input [7:0] is_write,
  input [7:0] is_shared,
  input [31:0] channel,
  input [63:0] hart_id,
  input [31:0] vbank_id,
  input [31:0] pbank_id,
  input [31:0] group_id,
  input [31:0] addr,
  input [63:0] data_lo,
  input [63:0] data_hi,
  input enable
);
endmodule

module PMCTraceDPI(
  input [31:0] ball_id,
  input [31:0] rob_id,
  input [63:0] elapsed,
  input enable
);
endmodule

module MemPMCTraceDPI(
  input [7:0] is_store,
  input [31:0] rob_id,
  input [63:0] elapsed,
  input enable
);
endmodule

module SCUWriteDPI(
  input clock,
  input reset,
  input [31:0] uart_hart_id,
  input uart_valid,
  input [7:0] uart_data,
  input [31:0] exit_hart_id,
  input exit_valid,
  input [31:0] exit_code
);
endmodule

module SCUReadDPI(
  input clock,
  input reset,
  input [31:0] hart_id,
  input enable,
  input pop,
  output logic rx_valid,
  output logic [7:0] rx_data
);
  assign rx_valid = 1'b0;
  assign rx_data = 8'h0;
endmodule
"""

MODULE_RE = re.compile(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\s*(?:#\s*\(.*?\)\s*)?\((.*?)\);\s*", re.S)
MODULE_NAME_RE = re.compile(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\b", re.S)
COMMENT_RE = re.compile(r"//.*?$|/\*.*?\*/", re.S | re.M)


@dataclass(frozen=True)
class Port:
    name: str
    direction: str
    width: int


@dataclass(frozen=True)
class Slice:
    bit_lo: int
    logical_width: int
    physical_depth: int
    physical_width: int
    compiler: str
    cell: str


def strip_comments(text: str) -> str:
    return COMMENT_RE.sub("", text)


def split_comma_list(text: str) -> list[str]:
    parts: list[str] = []
    start = 0
    bracket_depth = 0
    paren_depth = 0
    for index, char in enumerate(text):
        if char == "[":
            bracket_depth += 1
        elif char == "]":
            bracket_depth -= 1
        elif char == "(":
            paren_depth += 1
        elif char == ")":
            paren_depth -= 1
        elif char == "," and bracket_depth == 0 and paren_depth == 0:
            parts.append(text[start:index])
            start = index + 1
    tail = text[start:]
    if tail.strip():
        parts.append(tail)
    return parts


def parse_ports(source: Path) -> tuple[str, list[Port]]:
    text = strip_comments(source.read_text(errors="replace"))
    match = MODULE_RE.search(text)
    if match is None:
        raise ValueError(f"Cannot parse module header: {source}")

    current_direction: str | None = None
    current_width = 1
    ports: list[Port] = []
    for raw_item in split_comma_list(match.group(2)):
        item = " ".join(raw_item.strip().split())
        if not item:
            continue

        direction_match = re.search(r"\b(input|output|inout)\b", item)
        if direction_match:
            current_direction = direction_match.group(1)
            item = item[: direction_match.start()] + " " + item[direction_match.end() :]
            if "[" not in item:
                current_width = 1

        width_match = re.search(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", item)
        if width_match:
            current_width = abs(int(width_match.group(1)) - int(width_match.group(2))) + 1
            item = item[: width_match.start()] + " " + item[width_match.end() :]

        for keyword in ("wire", "logic", "reg", "signed"):
            item = re.sub(rf"\b{keyword}\b", " ", item)

        name_match = re.search(r"([A-Za-z_][A-Za-z0-9_$]*)\s*(?:=.*)?$", item.strip())
        if name_match and current_direction is not None:
            ports.append(Port(name_match.group(1), current_direction, current_width))

    return match.group(1), ports


def clog2(value: int) -> int:
    return max(1, math.ceil(math.log2(max(1, value))))


def width_decl(width: int) -> str:
    return "" if width == 1 else f"[{width - 1}:0] "


def sv_int(value: int) -> str:
    return str(int(value))


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as csv_file:
        return list(csv.DictReader(csv_file))


def resolve_rtl_path(raw_path: str) -> Path:
    candidate = Path(raw_path).expanduser()
    search_roots = []
    if candidate.is_absolute():
        search_roots.append(candidate)
    else:
        search_roots.extend(root / candidate for root in RTL_SOURCE_DIRS)
        search_roots.append((REPO_ROOT / candidate).resolve())

    search_roots.extend(root / candidate.name for root in RTL_SOURCE_DIRS)

    seen: set[Path] = set()
    for path in search_roots:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        if resolved.exists():
            return resolved

    raise FileNotFoundError(f"Cannot locate RTL source '{raw_path}'")


def macro_cell_name(row: dict[str, str]) -> str:
    db_files = row.get("db_files", "").split()
    if db_files:
        return Path(db_files[0]).name.split("_tt0p9v25c.db")[0].upper()
    lib_files = row.get("liberty_files", "").split()
    if lib_files:
        name = Path(lib_files[0]).name
        return re.sub(r"_(?:tt|ssg|ffg).*\.lib$", "", name).upper()
    raise ValueError(f"No db/lib file in manifest row for {row.get('rtl_module')}")


def port_map(ports: list[Port]) -> dict[str, Port]:
    return {port.name: port for port in ports}


def emit_module_header(lines: list[str], module: str, ports: list[Port]) -> None:
    lines.append(f"module {module}(")
    for index, port in enumerate(ports):
        comma = "," if index != len(ports) - 1 else ""
        lines.append(f"  {port.direction} logic {width_decl(port.width)}{port.name}{comma}")
    lines.append(");")
    lines.append("")


def emit_const(width: int, bit: str) -> str:
    return f"{width}'b{bit * width}" if width <= 128 else f"{{{width}{{1'b{bit}}}}}"


def emit_addr_pad(signal: str, signal_width: int, macro_width: int) -> str:
    if signal_width == macro_width:
        return signal
    if signal_width > macro_width:
        return f"{signal}[{macro_width - 1}:0]"
    return f"{{{macro_width - signal_width}'b0, {signal}}}"


def emit_signal_slice(signal: str, signal_width: int, bit_lo: int, used_bits: int) -> str:
    if signal_width == 1:
        return signal
    if used_bits == 1:
        return f"{signal}[{bit_lo}]"
    return f"{signal}[{bit_lo} +: {used_bits}]"


def emit_slice_expr(signal: str, signal_width: int, bit_lo: int, used_bits: int, physical_width: int) -> str:
    data_expr = emit_signal_slice(signal, signal_width, bit_lo, used_bits)
    if used_bits == physical_width:
        return data_expr
    return f"{{{physical_width - used_bits}'b0, {data_expr}}}"


def emit_read_assign(lines: list[str], target: str, source: str, bit_lo: int, used_bits: int) -> None:
    if used_bits == 1:
        lines.append(f"  assign {target}[{bit_lo}] = {source}[0];")
    else:
        lines.append(f"  assign {target}[{bit_lo} +: {used_bits}] = {source}[{used_bits - 1}:0];")


def mask_expr(module_width: int, mask_width: int | None, bit_index: int) -> str:
    if mask_width is None:
        return "1'b1"
    chunk = max(1, module_width // mask_width)
    mask_index = min(mask_width - 1, bit_index // chunk)
    return f"RW0_wmask[{mask_index}]"


def emit_spsram_instance(
    lines: list[str],
    inst: str,
    sl: Slice,
    addr_signal: str,
    addr_width: int,
    en_signal: str,
    write_signal: str,
    data_signal: str,
    bweb_signal: str,
    q_signal: str,
) -> None:
    aw = clog2(sl.physical_depth)
    lines.append(f"  {sl.cell} {inst} (")
    lines.append("    .SLP(1'b0),")
    lines.append("    .SD(1'b0),")
    lines.append("    .CLK(RW0_clk),")
    lines.append(f"    .CEB(~({en_signal})),")
    lines.append(f"    .WEB(~({en_signal} & {write_signal})),")
    lines.append("    .CEBM(1'b1),")
    lines.append("    .WEBM(1'b1),")
    lines.append("    .AWT(1'b0),")
    lines.append(f"    .A({emit_addr_pad(addr_signal, addr_width, aw)}),")
    lines.append(f"    .D({data_signal}),")
    lines.append(f"    .BWEB({bweb_signal}),")
    lines.append(f"    .AM({aw}'b0),")
    lines.append(f"    .DM({emit_const(sl.physical_width, '0')}),")
    lines.append(f"    .BWEBM({emit_const(sl.physical_width, '1')}),")
    lines.append("    .BIST(1'b0),")
    lines.append(f"    .Q({q_signal})")
    lines.append("  );")


def emit_2prf_instance(
    lines: list[str],
    inst: str,
    sl: Slice,
    read_addr: str,
    read_addr_width: int,
    read_en: str,
    read_clk: str,
    write_addr: str,
    write_addr_width: int,
    write_en: str,
    write_clk: str,
    data_signal: str,
    bweb_signal: str,
    q_signal: str,
) -> None:
    aw = clog2(sl.physical_depth)
    lines.append(f"  {sl.cell} {inst} (")
    lines.append(f"    .AA({emit_addr_pad(write_addr, write_addr_width, aw)}),")
    lines.append(f"    .D({data_signal}),")
    lines.append(f"    .BWEB({bweb_signal}),")
    lines.append(f"    .WEB(~({write_en})),")
    lines.append(f"    .CLKW({write_clk}),")
    lines.append(f"    .AB({emit_addr_pad(read_addr, read_addr_width, aw)}),")
    lines.append(f"    .REB(~({read_en})),")
    lines.append(f"    .CLKR({read_clk}),")
    lines.append(f"    .AMA({aw}'b0),")
    lines.append(f"    .DM({emit_const(sl.physical_width, '0')}),")
    lines.append(f"    .BWEBM({emit_const(sl.physical_width, '1')}),")
    lines.append("    .WEBM(1'b1),")
    lines.append(f"    .AMB({aw}'b0),")
    lines.append("    .REBM(1'b1),")
    lines.append("    .BIST(1'b0),")
    lines.append("    .SLP(1'b0),")
    lines.append("    .SD(1'b0),")
    lines.append(f"    .Q({q_signal})")
    lines.append("  );")


def emit_1rw(lines: list[str], module: str, ports: list[Port], rows: list[dict[str, str]]) -> None:
    pmap = port_map(ports)
    data_width = pmap["RW0_wdata"].width
    addr_width = pmap["RW0_addr"].width
    mask_width = pmap["RW0_wmask"].width if "RW0_wmask" in pmap else None

    emit_module_header(lines, module, ports)
    lines.append("  logic ren_d0;")
    lines.append("  logic wmode_d0;")
    lines.append(f"  logic [{data_width - 1}:0] rdata_comb;")
    lines.append("")
    lines.append("  always_ff @(posedge RW0_clk) begin")
    lines.append("    ren_d0 <= RW0_en;")
    lines.append("    wmode_d0 <= RW0_wmode;")
    lines.append("  end")
    lines.append("")

    for index, row in enumerate(rows):
        sl = Slice(
            bit_lo=int(row["logical_bit_lo"]),
            logical_width=int(row["slice_logical_width"]),
            physical_depth=int(row["physical_depth"]),
            physical_width=int(row["physical_width"]),
            compiler=row["compiler"],
            cell=macro_cell_name(row),
        )
        used = sl.logical_width
        lines.append(f"  logic [{sl.physical_width - 1}:0] d_{index};")
        lines.append(f"  logic [{sl.physical_width - 1}:0] bweb_{index};")
        lines.append(f"  logic [{sl.physical_width - 1}:0] q_{index};")
        lines.append(f"  assign d_{index} = {emit_slice_expr('RW0_wdata', data_width, sl.bit_lo, used, sl.physical_width)};")
        for bit in range(sl.physical_width):
            if bit < used:
                mexpr = mask_expr(data_width, mask_width, sl.bit_lo + bit)
                lines.append(f"  assign bweb_{index}[{bit}] = ~(RW0_en & RW0_wmode & {mexpr});")
            else:
                lines.append(f"  assign bweb_{index}[{bit}] = 1'b1;")
        emit_read_assign(lines, "rdata_comb", f"q_{index}", sl.bit_lo, used)
        emit_spsram_instance(
            lines,
            f"u_sram_{index}",
            sl,
            "RW0_addr",
            addr_width,
            "RW0_en",
            "RW0_wmode",
            f"d_{index}",
            f"bweb_{index}",
            f"q_{index}",
        )
        lines.append("")

    lines.append("  assign RW0_rdata = (ren_d0 && !wmode_d0) ? rdata_comb : " + f"{data_width}'bx;")
    lines.append("endmodule")
    lines.append("")


def emit_1r1w(lines: list[str], module: str, ports: list[Port], rows: list[dict[str, str]]) -> None:
    pmap = port_map(ports)
    data_width = pmap["W0_data"].width
    raddr_width = pmap["R0_addr"].width
    waddr_width = pmap["W0_addr"].width

    emit_module_header(lines, module, ports)
    lines.append(f"  logic [{data_width - 1}:0] rdata_comb;")
    lines.append("")
    for index, row in enumerate(rows):
        sl = Slice(
            bit_lo=int(row["logical_bit_lo"]),
            logical_width=int(row["slice_logical_width"]),
            physical_depth=int(row["physical_depth"]),
            physical_width=int(row["physical_width"]),
            compiler=row["compiler"],
            cell=macro_cell_name(row),
        )
        used = sl.logical_width
        lines.append(f"  logic [{sl.physical_width - 1}:0] d_{index};")
        lines.append(f"  logic [{sl.physical_width - 1}:0] bweb_{index};")
        lines.append(f"  logic [{sl.physical_width - 1}:0] q_{index};")
        lines.append(f"  assign d_{index} = {emit_slice_expr('W0_data', data_width, sl.bit_lo, used, sl.physical_width)};")
        lines.append(f"  assign bweb_{index} = {{{sl.physical_width}{{~W0_en}}}};")
        emit_read_assign(lines, "rdata_comb", f"q_{index}", sl.bit_lo, used)
        emit_2prf_instance(
            lines,
            f"u_sram_{index}",
            sl,
            "R0_addr",
            raddr_width,
            "R0_en",
            "R0_clk",
            "W0_addr",
            waddr_width,
            "W0_en",
            "W0_clk",
            f"d_{index}",
            f"bweb_{index}",
            f"q_{index}",
        )
        lines.append("")

    lines.append("  assign R0_data = R0_en ? rdata_comb : " + f"{data_width}'bx;")
    lines.append("endmodule")
    lines.append("")


def emit_2r1w(lines: list[str], module: str, ports: list[Port], rows: list[dict[str, str]]) -> None:
    pmap = port_map(ports)
    data_width = pmap["W0_data"].width
    waddr_width = pmap["W0_addr"].width
    read_ports = [0, 1]

    emit_module_header(lines, module, ports)
    for read_port in read_ports:
        lines.append(f"  logic [{data_width - 1}:0] r{read_port}_data_comb;")
    lines.append("")

    for index, row in enumerate(rows):
        sl = Slice(
            bit_lo=int(row["logical_bit_lo"]),
            logical_width=int(row["slice_logical_width"]),
            physical_depth=int(row["physical_depth"]),
            physical_width=int(row["physical_width"]),
            compiler=row["compiler"],
            cell=macro_cell_name(row),
        )
        used = sl.logical_width
        lines.append(f"  logic [{sl.physical_width - 1}:0] d_{index};")
        lines.append(f"  logic [{sl.physical_width - 1}:0] bweb_{index};")
        lines.append(f"  assign d_{index} = {emit_slice_expr('W0_data', data_width, sl.bit_lo, used, sl.physical_width)};")
        lines.append(f"  assign bweb_{index} = {{{sl.physical_width}{{~W0_en}}}};")
        for read_port in read_ports:
            qname = f"q_r{read_port}_{index}"
            lines.append(f"  logic [{sl.physical_width - 1}:0] {qname};")
            emit_read_assign(lines, f"r{read_port}_data_comb", qname, sl.bit_lo, used)
            emit_2prf_instance(
                lines,
                f"u_sram_r{read_port}_{index}",
                sl,
                f"R{read_port}_addr",
                pmap[f"R{read_port}_addr"].width,
                f"R{read_port}_en",
                f"R{read_port}_clk",
                "W0_addr",
                waddr_width,
                "W0_en",
                "W0_clk",
                f"d_{index}",
                f"bweb_{index}",
                qname,
            )
        lines.append("")

    for read_port in read_ports:
        lines.append(
            f"  assign R{read_port}_data = R{read_port}_en ? r{read_port}_data_comb : {data_width}'bx;"
        )
    lines.append("endmodule")
    lines.append("")


def generate_replacements(manifest: Path, rtl_manifest: Path, out_path: Path) -> set[str]:
    rows = [row for row in read_csv(manifest) if row.get("status") == "ok"]
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["rtl_module"]].append(row)

    rtl_rows = {row["module"]: row for row in read_csv(rtl_manifest)}
    lines = [
        "// Auto-generated by scripts/sramReplace.py.",
        "// Do not edit by hand; update real_sram_libs manifests and rerun the script.",
        "",
    ]
    replaced: set[str] = set()
    skipped_missing_source: list[tuple[str, str]] = []
    for module in sorted(grouped):
        rtl_row = rtl_rows[module]
        try:
            source = resolve_rtl_path(rtl_row["source"])
        except FileNotFoundError:
            skipped_missing_source.append((module, rtl_row["source"]))
            continue
        _, ports = parse_ports(source)
        module_rows = sorted(grouped[module], key=lambda row: int(row["logical_bit_lo"]))
        port_type = rtl_row["port_type"]
        if port_type == "1RW":
            emit_1rw(lines, module, ports, module_rows)
        elif port_type == "1R1W":
            emit_1r1w(lines, module, ports, module_rows)
        elif port_type == "2R1W":
            emit_2r1w(lines, module, ports, module_rows)
        else:
            continue
        replaced.add(module)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines))
    for module, source in skipped_missing_source:
        print(f"Warning: skipping SRAM replacement for {module}; source RTL not found: {source}")
    if skipped_missing_source:
        print(f"Warning: skipped {len(skipped_missing_source)} manifest entries with missing source RTL")
    return replaced


def file_module_name(path: Path) -> str | None:
    try:
        text = strip_comments(path.read_text(errors="replace"))
    except OSError:
        return None
    match = MODULE_NAME_RE.search(text)
    return match.group(1) if match else None


def source_filelist_entries() -> list[Path]:
    entries: list[Path] = []
    seen: set[Path] = set()
    skipped_missing: list[str] = []
    if SOURCE_FILELIST.exists():
        for raw in SOURCE_FILELIST.read_text(errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                candidate = resolve_rtl_path(line)
            except FileNotFoundError:
                skipped_missing.append(line)
                continue
            if candidate not in seen:
                entries.append(candidate)
                seen.add(candidate)

    for pattern in ("*.sv", "*.v"):
        for candidate in sorted(RTL_DIR.glob(pattern)):
            resolved = candidate.resolve()
            if resolved not in seen:
                entries.append(resolved)
                seen.add(resolved)
    for line in skipped_missing:
        print(f"Warning: skipping missing filelist entry: {line}")
    if skipped_missing:
        print(f"Warning: skipped {len(skipped_missing)} missing source filelist entries")
    return entries


def write_filelist(filelist: Path, replaced_modules: set[str], replacement_rtl: Path) -> None:
    out: list[Path] = []
    replacement = replacement_rtl.resolve()
    stubs = SYNTHESIS_STUBS.resolve()
    for path in source_filelist_entries():
        resolved = path.resolve()
        if resolved in {replacement, stubs}:
            continue
        module = file_module_name(path)
        if module in SYNTHESIS_EXCLUDED_MODULES:
            continue
        if module in replaced_modules:
            continue
        out.append(resolved)

    if SYNTHESIS_STUBS.exists():
        out.append(stubs)

    filelist.parent.mkdir(parents=True, exist_ok=True)
    filelist.write_text("\n".join(str(path) for path in out) + "\n")


def write_synthesis_stubs(path: Path = SYNTHESIS_STUBS) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(SYNTHESIS_STUBS_TEXT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--rtl-manifest", type=Path, default=DEFAULT_RTL_MANIFEST)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--filelist", type=Path, default=DEFAULT_FILELIST)
    args = parser.parse_args()

    replaced = generate_replacements(args.manifest.resolve(), args.rtl_manifest.resolve(), args.out.resolve())
    write_synthesis_stubs()
    write_filelist(args.filelist.resolve(), replaced, args.out.resolve())

    print(f"Generated {args.out}")
    print(f"Generated {SYNTHESIS_STUBS}")
    print(f"Generated {args.filelist}")
    print(f"Replaced SRAM modules: {len(replaced)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
