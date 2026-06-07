#!/usr/bin/env python3
"""Filter selected internal VCD scopes while preserving shared boundary signals."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


VALUE_RE = re.compile(r"^[01xXzZ]([!-~]+)\s*$")
VECTOR_RE = re.compile(r"^[bBrR][^\s]+\s+([!-~]+)\s*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove VCD variables below a scope but keep the scope's own ports."
    )
    parser.add_argument("--in", dest="in_file", required=True, help="input VCD")
    parser.add_argument("--out", dest="out_file", required=True, help="output VCD")
    parser.add_argument(
        "--scope",
        action="append",
        required=True,
        help="dot-separated scope whose child scopes should be removed",
    )
    return parser.parse_args()


def value_idcode(line: str) -> str | None:
    match = VALUE_RE.match(line)
    if match:
        return match.group(1)
    match = VECTOR_RE.match(line)
    if match:
        return match.group(1)
    return None


def filter_vcd(in_file: Path, out_file: Path, scopes: set[tuple[str, ...]]) -> None:
    stack: list[str] = []
    remove_depths: list[int] = []
    removed_idcodes: set[str] = set()
    kept_idcodes: set[str] = set()
    in_header = True

    out_file.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{out_file.name}.", suffix=".tmp", dir=str(out_file.parent)
    )
    os.close(fd)
    tmp_path = Path(tmp_name)

    try:
        with in_file.open("r", encoding="utf-8", errors="replace") as src, tmp_path.open(
            "w", encoding="utf-8"
        ) as dst:
            for line in src:
                if in_header:
                    if line.startswith("$scope "):
                        parts = line.split()
                        stack.append(parts[2])
                        if tuple(stack[:-1]) in scopes:
                            remove_depths.append(len(stack))
                        if remove_depths:
                            continue
                    elif line.startswith("$upscope"):
                        dropping = bool(remove_depths)
                        if remove_depths and len(stack) == remove_depths[-1]:
                            remove_depths.pop()
                        if stack:
                            stack.pop()
                        if dropping:
                            continue
                    elif remove_depths:
                        if line.startswith("$var "):
                            parts = line.split()
                            if len(parts) >= 5:
                                removed_idcodes.add(parts[3])
                        continue
                    elif line.startswith("$var "):
                        parts = line.split()
                        if len(parts) >= 5:
                            kept_idcodes.add(parts[3])
                    elif line.startswith("$enddefinitions"):
                        in_header = False

                    dst.write(line)
                    continue

                idcode = value_idcode(line)
                if idcode is not None and idcode in removed_idcodes and idcode not in kept_idcodes:
                    continue
                dst.write(line)

        tmp_path.replace(out_file)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def main() -> None:
    args = parse_args()
    scopes = {tuple(scope.split(".")) for scope in args.scope}
    filter_vcd(Path(args.in_file), Path(args.out_file), scopes)


if __name__ == "__main__":
    main()
