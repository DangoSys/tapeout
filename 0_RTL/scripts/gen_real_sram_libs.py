#!/usr/bin/env python3
"""Generate real TSMC28 SRAM/RF compiler deliverables for RTL memories.

The script scans 0_RTL/RTL for modules containing a ``Memory`` array, classifies
their port shape, maps supported memories onto available TSMC28 compilers, and
emits real NLDM/Verilog/LEF/GDSII/SPICE kits plus Design Compiler .db files.

Supported mappings:
  * 1RW       -> tsn28hpcpd127spsram
  * 1R1W      -> tsn28hpcp2prf, with horizontal slicing as needed
  * 2R1W      -> duplicated tsn28hpcp2prf implementation, one macro copy per read

Unsupported memories are reported in unsupported.csv instead of receiving fake
libraries.
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import re
import shutil
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_STAGE_DIR = Path(os.environ.get("RTL_STAGE_DIR", REPO_ROOT / os.environ.get("RTL_STAGE_DIR_NAME", "0_RTL")))
DEFAULT_RTL_DIR = RTL_STAGE_DIR / "RTL"
DEFAULT_OUT_DIR = RTL_STAGE_DIR / "real_sram_libs"

MC2_BIN_DIR = Path(
    "/data0/tsmc28/TSMC28/Memory/1/tsmc_n28hpcpmc_20120200_110a/"
    "AN61001_20180125/TSMCHOME/sram/Compiler/"
    "tsmc_n28hpcpmc_20120200_110a/MC2_2012.02.00.d/bin/Linux-64"
)
LC_SHELL = Path("/data2/tools/lc/R-2020.09-SP5/linux64/lc/bin/lc_shell")
LC_LD_LIBRARY_PATH = (
    "/data0/tools/Synopsys/dc/syn/W-2024.09-SP1/linux64/syn/shlib:"
    "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:"
    "/usr/lib/x86_64-linux-gnu/pulseaudio"
)

SPSRAM_COMPILER_DIR = Path(
    "/data0/tsmc28/TSMC28/Memory/tsn28hpcpd127spsram_20120200_180a/"
    "AN61001_20180416/TSMCHOME/sram/Compiler/tsn28hpcpd127spsram_20120200_180a"
)
PRF2_OUTER_TAR = Path(
    "/data0/tsmc28/TSMC28/Memory/tsn28hpcp2prf_20120200_130a/"
    "AN61001_20180125/tsn28hpcp2prf_20120200_130a.tar.gz"
)

MODULE_RE = re.compile(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\s*\((.*?)\);\s*", re.S)
MEMORY_RE = re.compile(
    r"\breg\s+(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s+)?Memory\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]",
    re.S,
)
COMMENT_RE = re.compile(r"//.*?$|/\*.*?\*/", re.S | re.M)
LIBRARY_RE = re.compile(r"\blibrary\s*\(\s*([^)\s]+)\s*\)")


@dataclass(frozen=True)
class Port:
    name: str
    direction: str
    width: int


@dataclass(frozen=True)
class SramModule:
    name: str
    source: Path
    depth: int
    width: int
    ports: tuple[Port, ...]


@dataclass(frozen=True)
class Compiler:
    key: str
    pl_name: str
    mco_name: str
    source_dir: Path | None
    outer_tar: Path | None
    version_suffix: str
    min_depth: int
    legal_depths: tuple[int, ...]
    legal_widths: tuple[int, ...]
    mux: int
    segment: str
    pvt: str = "tt0p9v25c"


@dataclass(frozen=True)
class MacroSpec:
    compiler: Compiler
    depth: int
    width: int

    @property
    def config_line(self) -> str:
        return f"{self.depth}x{self.width}m{self.compiler.mux}{self.compiler.segment}"

    @property
    def key(self) -> str:
        return f"{self.compiler.key}_{self.config_line}"


@dataclass(frozen=True)
class SlicePlan:
    module: SramModule
    port_type: str
    implementation: str
    logical_lo: int
    logical_width: int
    macro: MacroSpec
    copies: int


SPSRAM = Compiler(
    key="tsn28hpcpd127spsram",
    pl_name="tsn28hpcpd127spsram_180a.pl",
    mco_name="tsn28hpcpd127spsram_20120200_180a.mco",
    source_dir=SPSRAM_COMPILER_DIR,
    outer_tar=None,
    version_suffix="180a",
    min_depth=32,
    legal_depths=(32, 64, 128, 256, 512, 1024, 2048, 4096, 8192),
    legal_widths=tuple(range(8, 145, 8)),
    mux=4,
    segment="s",
)

PRF2 = Compiler(
    key="tsn28hpcp2prf",
    pl_name="tsn28hpcp2prf_130a.pl",
    mco_name="tsn28hpcp2prf_20120200_130a.mco",
    source_dir=None,
    outer_tar=PRF2_OUTER_TAR,
    version_suffix="130a",
    min_depth=16,
    legal_depths=(16, 32, 64, 128, 256, 512),
    legal_widths=(2, 16, 32, 48, 64, 80, 96, 112, 128, 144),
    mux=2,
    segment="f",
)


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


def parse_ports(header: str) -> tuple[Port, ...]:
    current_direction: str | None = None
    current_width = 1
    ports: list[Port] = []

    for raw_item in split_comma_list(header):
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

    return tuple(ports)


def discover_sram_modules(rtl_dir: Path) -> list[SramModule]:
    modules: list[SramModule] = []
    for source in sorted(rtl_dir.glob("*.sv")):
        text = strip_comments(source.read_text(errors="replace"))
        module_match = MODULE_RE.search(text)
        memory_match = MEMORY_RE.search(text)
        if module_match is None or memory_match is None:
            continue

        data_msb = int(memory_match.group(1)) if memory_match.group(1) is not None else 0
        data_lsb = int(memory_match.group(2)) if memory_match.group(2) is not None else 0
        depth_a = int(memory_match.group(3))
        depth_b = int(memory_match.group(4))
        modules.append(
            SramModule(
                name=module_match.group(1),
                source=source,
                depth=abs(depth_a - depth_b) + 1,
                width=abs(data_msb - data_lsb) + 1,
                ports=parse_ports(module_match.group(2)),
            )
        )
    return modules


def classify_ports(module: SramModule) -> str:
    port_names = {port.name for port in module.ports}
    if any(name.startswith("RW0_") for name in port_names):
        return "1RW"

    read_ports = {
        match.group(1)
        for name in port_names
        if (match := re.fullmatch(r"R(\d+)_data", name)) is not None
    }
    write_ports = {
        match.group(1)
        for name in port_names
        if (match := re.fullmatch(r"W(\d+)_data", name)) is not None
    }
    if len(read_ports) == 1 and len(write_ports) == 1:
        return "1R1W"
    if len(read_ports) == 2 and len(write_ports) == 1:
        return "2R1W"
    if len(read_ports) == 1 and len(write_ports) == 2:
        return "1R2W"
    if len(read_ports) == 3 and len(write_ports) == 2:
        return "3R2W"
    return f"{len(read_ports)}R{len(write_ports)}W"


def next_legal(value: int, legal_values: tuple[int, ...], label: str) -> int:
    for legal in legal_values:
        if legal >= value:
            return legal
    raise ValueError(f"No legal {label} >= {value}; max supported is {legal_values[-1]}")


def width_chunks(width: int, legal_widths: tuple[int, ...]) -> list[tuple[int, int, int]]:
    chunks: list[tuple[int, int, int]] = []
    max_width = legal_widths[-1]
    bit_lo = 0
    remaining = width
    while remaining > 0:
        logical_width = min(remaining, max_width)
        physical_width = next_legal(logical_width, legal_widths, "width")
        chunks.append((bit_lo, logical_width, physical_width))
        bit_lo += logical_width
        remaining -= logical_width
    return chunks


def plan_module(module: SramModule) -> tuple[str, list[SlicePlan], str]:
    port_type = classify_ports(module)
    if port_type == "1RW":
        compiler = SPSRAM
        implementation = "direct_spsram"
        copies = 1
    elif port_type == "1R1W":
        compiler = PRF2
        implementation = "direct_2prf"
        copies = 1
    elif port_type == "2R1W":
        compiler = PRF2
        implementation = "duplicated_2prf"
        copies = 2
    else:
        return port_type, [], "unsupported_port_topology"

    try:
        physical_depth = next_legal(max(module.depth, compiler.min_depth), compiler.legal_depths, "depth")
    except ValueError as exc:
        return port_type, [], str(exc)

    plans = [
        SlicePlan(
            module=module,
            port_type=port_type,
            implementation=implementation,
            logical_lo=bit_lo,
            logical_width=logical_width,
            macro=MacroSpec(compiler=compiler, depth=physical_depth, width=physical_width),
            copies=copies,
        )
        for bit_lo, logical_width, physical_width in width_chunks(module.width, compiler.legal_widths)
    ]
    return port_type, plans, ""


def copy_compiler_from_dir(compiler: Compiler, dst: Path) -> None:
    assert compiler.source_dir is not None
    for name in ("README", "config.txt", compiler.pl_name, compiler.mco_name):
        source = compiler.source_dir / name
        if source.exists():
            target = dst / name
            if target.exists():
                target.chmod(target.stat().st_mode | 0o200)
                target.unlink()
            shutil.copy2(source, target)


def copy_compiler_from_nested_tar(compiler: Compiler, dst: Path) -> None:
    assert compiler.outer_tar is not None
    with tarfile.open(compiler.outer_tar, "r:gz") as outer:
        inner_name = None
        for member in outer.getmembers():
            if member.name.endswith(f"/{compiler.key}_20120200_130a.tar.gz"):
                inner_name = member.name
                break
        if inner_name is None:
            raise FileNotFoundError(f"Cannot find nested compiler tar in {compiler.outer_tar}")
        inner_file = outer.extractfile(inner_name)
        if inner_file is None:
            raise FileNotFoundError(f"Cannot extract {inner_name} from {compiler.outer_tar}")
        inner_bytes = io.BytesIO(inner_file.read())

    with tarfile.open(fileobj=inner_bytes, mode="r:gz") as inner:
        wanted = {"README", "config.txt", compiler.pl_name, compiler.mco_name}
        for member in inner.getmembers():
            if Path(member.name).name not in wanted:
                continue
            extracted = inner.extractfile(member)
            if extracted is None:
                continue
            target = dst / Path(member.name).name
            if target.exists():
                target.chmod(target.stat().st_mode | 0o200)
                target.unlink()
            target.write_bytes(extracted.read())


def prepare_run_dir(spec: MacroSpec, run_dir: Path) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    if spec.compiler.source_dir is not None:
        copy_compiler_from_dir(spec.compiler, run_dir)
    else:
        copy_compiler_from_nested_tar(spec.compiler, run_dir)
    for path in run_dir.iterdir():
        if path.is_file():
            path.chmod(path.stat().st_mode | 0o200)
    config_path = run_dir / "config.txt"
    if config_path.exists():
        config_path.unlink()
    config_path.write_text(spec.config_line + "\n")
    for filename in (spec.compiler.pl_name, spec.compiler.mco_name):
        path = run_dir / filename
        if not path.exists():
            raise FileNotFoundError(f"Compiler file missing after setup: {path}")


def kit_dir(run_dir: Path, pvt: str) -> Path | None:
    candidates = []
    for nldm_lib in run_dir.glob(f"*/NLDM/*_{pvt}.lib"):
        base = nldm_lib.parents[1]
        if has_complete_kit(base, pvt):
            candidates.append(base)
    if not candidates:
        return None
    return sorted(candidates)[0]


def has_complete_kit(base: Path, pvt: str) -> bool:
    checks = [
        list((base / "NLDM").glob(f"*_{pvt}.lib")),
        list((base / "VERILOG").glob(f"*_{pvt}.v")),
        list((base / "LEF").glob("*.lef")),
        list((base / "GDSII").glob("*.gds")),
        list((base / "SPICE").glob("*.spi")),
    ]
    return all(checks)


def run_compiler(spec: MacroSpec, run_dir: Path, force: bool) -> tuple[bool, str, Path | None]:
    if not force:
        existing = kit_dir(run_dir, spec.compiler.pvt)
        if existing is not None:
            return True, "reused", existing

    if force and run_dir.exists():
        shutil.rmtree(run_dir)
    prepare_run_dir(spec, run_dir)

    env = os.environ.copy()
    env["PATH"] = f"{MC2_BIN_DIR}:{env.get('PATH', '')}"
    env["MC_HOME"] = str(run_dir)
    env.setdefault("LM_LICENSE_FILE", "26000@amax")

    cmd = [
        "perl",
        spec.compiler.pl_name,
        "-file",
        "config.txt",
        "-PVT",
        spec.compiler.pvt,
        "-NLDM",
        "-VERILOG",
        "-LEF",
        "-GDSII",
        "-SPICE",
    ]
    log_path = run_dir / "run.log"
    with log_path.open("w") as log_file:
        proc = subprocess.run(
            cmd,
            cwd=run_dir,
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    generated = kit_dir(run_dir, spec.compiler.pvt)
    if proc.returncode != 0:
        return False, f"compiler_exit_{proc.returncode}; see {log_path}", None
    if generated is None:
        return False, f"compiler_output_missing; see {log_path}", None
    return True, "generated", generated


def parse_library_name(lib_path: Path) -> str:
    text = lib_path.read_text(errors="replace")
    match = LIBRARY_RE.search(text)
    if match is None:
        raise ValueError(f"Cannot find library() name in {lib_path}")
    return match.group(1)


def q(path: Path) -> str:
    return "{" + str(path).replace("\\", "/").replace("}", "\\}") + "}"


def write_db_tcl(lib_files: list[Path], db_dir: Path, tcl_path: Path) -> list[tuple[Path, Path, str]]:
    jobs: list[tuple[Path, Path, str]] = []
    for lib_file in lib_files:
        lib_name = parse_library_name(lib_file)
        jobs.append((lib_file, db_dir / f"{lib_name}.db", lib_name))

    lines = ["# Auto-generated by gen_real_sram_libs.py.", "set failed 0", f"file mkdir {q(db_dir)}"]
    lines.append("set jobs [list \\")
    for lib_file, db_file, lib_name in jobs:
        lines.append(f"  [list {q(lib_file)} {q(db_file)} {{{lib_name}}}] \\")
    lines.append("]")
    lines.extend(
        [
            "foreach job $jobs {",
            "  set lib_file [lindex $job 0]",
            "  set db_file [lindex $job 1]",
            "  set lib_name [lindex $job 2]",
            '  puts "Compiling $lib_file -> $db_file"',
            "  if {[catch {read_lib $lib_file} err]} {",
            '    puts stderr "ERROR: read_lib failed for $lib_file: $err"',
            "    incr failed",
            "    continue",
            "  }",
            "  if {[catch {write_lib $lib_name -format db -output $db_file} err]} {",
            '    puts stderr "ERROR: write_lib failed for $lib_name: $err"',
            "    incr failed",
            "    continue",
            "  }",
            "}",
            "if {$failed != 0} { exit 1 }",
            "exit 0",
            "",
        ]
    )
    tcl_path.write_text("\n".join(lines))
    return jobs


def run_lc_shell(tcl_path: Path, log_path: Path) -> None:
    env = {
        "HOME": os.environ.get("HOME", str(Path.home())),
        "USER": os.environ.get("USER", "user"),
        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "user")),
        "TERM": os.environ.get("TERM", "dumb"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LM_LICENSE_FILE": "26000@amax",
        "SNPSLMD_LICENSE_FILE": os.environ.get("SNPSLMD_LICENSE_FILE", "26000@amax"),
        "LD_LIBRARY_PATH": LC_LD_LIBRARY_PATH,
    }
    with log_path.open("w") as log_file:
        subprocess.run(
            [str(LC_SHELL), "-f", str(tcl_path)],
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )


def rel_symlink(source: Path, link: Path) -> None:
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(os.path.relpath(source, link.parent))


def collect_kit_files(kit: Path, pvt: str) -> dict[str, list[Path]]:
    return {
        "lib": sorted((kit / "NLDM").glob(f"*_{pvt}.lib")),
        "verilog": sorted((kit / "VERILOG").glob("*.v")),
        "lef": sorted((kit / "LEF").glob("*.lef")),
        "gds": sorted((kit / "GDSII").glob("*.gds")),
        "spice": sorted((kit / "SPICE").glob("*.spi")),
    }


def write_library_fragment(out_dir: Path, lib_files: list[Path], db_files: list[Path]) -> None:
    fragment = out_dir / "sram_library_files.tcl"
    lines = [
        "# Auto-generated by gen_real_sram_libs.py.",
        "# Source this from synthesis/power scripts after real_sram_libs generation.",
        "set REAL_SRAM_NLDM_FILES [list \\",
    ]
    for lib_file in lib_files:
        lines.append(f"  {q(lib_file)} \\")
    lines.append("]")
    lines.append("set REAL_SRAM_DB_FILES [list \\")
    for db_file in db_files:
        lines.append(f"  {q(db_file)} \\")
    lines.append("]")
    lines.append("")
    fragment.write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl-dir", type=Path, default=DEFAULT_RTL_DIR)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--skip-db", action="store_true", help="Do not run Library Compiler for .db conversion.")
    parser.add_argument("--force", action="store_true", help="Regenerate compiler runs even if complete kits already exist.")
    parser.add_argument("--discover-only", action="store_true", help="Only write manifests; do not run compilers.")
    args = parser.parse_args()

    rtl_dir = args.rtl_dir.resolve()
    out_dir = args.out_dir.resolve()
    run_root = out_dir / "compiler_runs"
    summary_root = out_dir / "summary"
    db_dir = summary_root / "db"
    out_dir.mkdir(parents=True, exist_ok=True)
    run_root.mkdir(parents=True, exist_ok=True)

    modules = discover_sram_modules(rtl_dir)
    if not modules:
        raise SystemExit(f"No SRAM-like Memory modules found under {rtl_dir}")

    rtl_rows: list[dict[str, object]] = []
    slice_plans: list[SlicePlan] = []
    unsupported_rows: list[dict[str, object]] = []

    for module in modules:
        port_type, plans, reason = plan_module(module)
        status = "supported" if plans else "unsupported"
        rtl_rows.append(
            {
                "module": module.name,
                "source": module.source,
                "logical_depth": module.depth,
                "logical_width": module.width,
                "port_type": port_type,
                "status": status,
                "reason": reason,
            }
        )
        if plans:
            slice_plans.extend(plans)
        else:
            unsupported_rows.append(rtl_rows[-1])

    unique_specs = sorted({plan.macro for plan in slice_plans}, key=lambda spec: spec.key)
    macro_results: dict[MacroSpec, tuple[bool, str, Path | None]] = {}

    if not args.discover_only:
        for index, spec in enumerate(unique_specs, start=1):
            run_dir = run_root / spec.compiler.key / spec.config_line
            print(f"[{index}/{len(unique_specs)}] {spec.key}")
            macro_results[spec] = run_compiler(spec, run_dir, args.force)
    else:
        for spec in unique_specs:
            macro_results[spec] = (False, "discover_only", None)

    completed_kits = sorted(
        {kit for ok, _, kit in macro_results.values() if ok and kit is not None}
    )
    all_lib_files: list[Path] = []
    summary_links: dict[tuple[Path, str], Path] = {}
    for kit in completed_kits:
        files = collect_kit_files(kit, "tt0p9v25c")
        macro_name = kit.name
        for kind, paths in files.items():
            for source in paths:
                link = summary_root / kind / macro_name / source.name
                rel_symlink(source, link)
                summary_links[(source, kind)] = link
                if kind == "lib":
                    all_lib_files.append(source)

    db_jobs: list[tuple[Path, Path, str]] = []
    if all_lib_files and not args.skip_db and not args.discover_only:
        db_tcl = out_dir / "compile_db.tcl"
        db_jobs = write_db_tcl(all_lib_files, db_dir, db_tcl)
        missing_db = [db_file for _, db_file, _ in db_jobs if not db_file.exists() or db_file.stat().st_size == 0]
        if missing_db or args.force:
            run_lc_shell(db_tcl, out_dir / "lc_shell.log")

    db_by_lib = {lib_file: db_file for lib_file, db_file, _ in db_jobs}
    for lib_file, db_file, _ in db_jobs:
        if db_file.exists():
            link = summary_root / "db" / db_file.name
            if link != db_file:
                rel_symlink(db_file, link)

    macro_manifest = out_dir / "macro_manifest.csv"
    with macro_manifest.open("w", newline="") as csv_file:
        fieldnames = [
            "rtl_module",
            "port_type",
            "implementation",
            "copies",
            "logical_depth",
            "logical_width",
            "logical_bit_lo",
            "slice_logical_width",
            "physical_depth",
            "physical_width",
            "compiler",
            "config",
            "status",
            "message",
            "kit_dir",
            "liberty_files",
            "db_files",
            "verilog_files",
            "lef_files",
            "gds_files",
            "spice_files",
        ]
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for plan in slice_plans:
            ok, message, kit = macro_results.get(plan.macro, (False, "not_run", None))
            files = collect_kit_files(kit, "tt0p9v25c") if kit is not None else {}
            lib_files = files.get("lib", [])
            db_files = [db_by_lib[path] for path in lib_files if path in db_by_lib and db_by_lib[path].exists()]
            writer.writerow(
                {
                    "rtl_module": plan.module.name,
                    "port_type": plan.port_type,
                    "implementation": plan.implementation,
                    "copies": plan.copies,
                    "logical_depth": plan.module.depth,
                    "logical_width": plan.module.width,
                    "logical_bit_lo": plan.logical_lo,
                    "slice_logical_width": plan.logical_width,
                    "physical_depth": plan.macro.depth,
                    "physical_width": plan.macro.width,
                    "compiler": plan.macro.compiler.key,
                    "config": plan.macro.config_line,
                    "status": "ok" if ok else "failed",
                    "message": message,
                    "kit_dir": kit or "",
                    "liberty_files": " ".join(str(path) for path in lib_files),
                    "db_files": " ".join(str(path) for path in db_files),
                    "verilog_files": " ".join(str(path) for path in files.get("verilog", [])),
                    "lef_files": " ".join(str(path) for path in files.get("lef", [])),
                    "gds_files": " ".join(str(path) for path in files.get("gds", [])),
                    "spice_files": " ".join(str(path) for path in files.get("spice", [])),
                }
            )

    with (out_dir / "rtl_sram_manifest.csv").open("w", newline="") as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=["module", "source", "logical_depth", "logical_width", "port_type", "status", "reason"],
        )
        writer.writeheader()
        writer.writerows(rtl_rows)

    with (out_dir / "unsupported.csv").open("w", newline="") as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=["module", "source", "logical_depth", "logical_width", "port_type", "status", "reason"],
        )
        writer.writeheader()
        writer.writerows(unsupported_rows)

    db_files = [db_file for _, db_file, _ in db_jobs if db_file.exists()]
    write_library_fragment(out_dir, all_lib_files, db_files)

    failed_specs = [spec for spec, (ok, _, _) in macro_results.items() if not ok]
    print(f"RTL SRAM modules: {len(modules)}")
    print(f"Supported modules: {len(rtl_rows) - len(unsupported_rows)}")
    print(f"Unsupported modules: {len(unsupported_rows)}")
    print(f"Unique physical macros: {len(unique_specs)}")
    print(f"Completed physical macros: {len(unique_specs) - len(failed_specs)}")
    print(f"Output: {out_dir}")
    if args.discover_only:
        return 0
    if failed_specs:
        print(f"Failed physical macros: {len(failed_specs)}; see {macro_manifest}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
