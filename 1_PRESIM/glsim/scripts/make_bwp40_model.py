#!/usr/bin/env python3
from pathlib import Path
from collections import defaultdict
import argparse
import re


def gate_expr(cell: str, ports: list[str]) -> tuple[str, str]:
    out = "ZN" if "ZN" in ports else "Z" if "Z" in ports else "Q" if "Q" in ports else "S"

    if cell.startswith(("INV", "CKND")) and ports == ["I", out]:
        return out, "~I"
    if cell.startswith(("BUF", "CKB")) and ports == ["I", out]:
        return out, "I"
    if cell.startswith("CKAN2") or cell.startswith("AN2"):
        return out, "A1 & A2"
    if cell.startswith("AN3"):
        return out, "A1 & A2 & A3"
    if cell.startswith("AN4"):
        return out, "A1 & A2 & A3 & A4"
    if cell.startswith("OR2"):
        return out, "A1 | A2"
    if cell.startswith("OR3"):
        return out, "A1 | A2 | A3"
    if cell.startswith("OR4"):
        return out, "A1 | A2 | A3 | A4"
    if cell.startswith(("ND2", "CKND2")):
        return out, "~(A1 & A2)"
    if cell.startswith("ND3"):
        return out, "~(A1 & A2 & A3)"
    if cell.startswith("ND4"):
        return out, "~(A1 & A2 & A3 & A4)"
    if cell.startswith("NR2"):
        return out, "~(A1 | A2)"
    if cell.startswith("NR3"):
        return out, "~(A1 | A2 | A3)"
    if cell.startswith("NR4"):
        return out, "~(A1 | A2 | A3 | A4)"
    if cell.startswith("AO211"):
        return out, "(A1 & A2) | B | C"
    if cell.startswith("AO221"):
        return out, "(A1 & A2) | (B1 & B2) | C"
    if cell.startswith("AO222"):
        return out, "(A1 & A2) | (B1 & B2) | (C1 & C2)"
    if cell.startswith("AO21"):
        return out, "(A1 & A2) | B"
    if cell.startswith("AO22"):
        return out, "(A1 & A2) | (B1 & B2)"
    if cell.startswith("AOI211"):
        return out, "~((A1 & A2) | B | C)"
    if cell.startswith("AOI221"):
        return out, "~((A1 & A2) | (B1 & B2) | C)"
    if cell.startswith("AOI222"):
        return out, "~((A1 & A2) | (B1 & B2) | (C1 & C2))"
    if cell.startswith("AOI32"):
        return out, "~((A1 & A2 & A3) | (B1 & B2))"
    if cell.startswith("AOI21"):
        return out, "~((A1 & A2) | B)"
    if cell.startswith("AOI22"):
        return out, "~((A1 & A2) | (B1 & B2))"
    if cell.startswith("AOI31"):
        return out, "~((A1 & A2 & A3) | B)"
    if cell.startswith("OA211"):
        return out, "(A1 | A2) & B & C"
    if cell.startswith("OA21"):
        return out, "(A1 | A2) & B"
    if cell.startswith("OA22"):
        return out, "(A1 | A2) & (B1 | B2)"
    if cell.startswith("OAI211"):
        return out, "~((A1 | A2) & B & C)"
    if cell.startswith("OAI222"):
        return out, "~((A1 | A2) & (B1 | B2) & (C1 | C2))"
    if cell.startswith("OAI32"):
        return out, "~((A1 | A2 | A3) & (B1 | B2))"
    if cell.startswith("OAI21"):
        return out, "~((A1 | A2) & B)"
    if cell.startswith("OAI22"):
        return out, "~((A1 | A2) & (B1 | B2))"
    if cell.startswith("OAI31"):
        return out, "~((A1 | A2 | A3) & B)"
    if cell.startswith("IAO21"):
        return out, "(~A1 & A2) | B"
    if cell.startswith("IOA21"):
        return out, "(~A1 | A2) & B"
    if cell.startswith("IAO22"):
        return out, "(~A1 & A2) | (B1 & B2)"
    if cell.startswith("IOA22"):
        return out, "(~A1 | A2) & (B1 | B2)"
    if cell.startswith("IND2"):
        return out, "~(~A1 & B1)"
    if cell.startswith("IND3"):
        return out, "~(~A1 & B1 & B2)"
    if cell.startswith("IND4"):
        return out, "~(~A1 & B1 & B2 & B3)"
    if cell.startswith("INR2"):
        return out, "~(~A1 | B1)"
    if cell.startswith("INR3"):
        return out, "~(~A1 | B1 | B2)"
    if cell.startswith("INR4"):
        return out, "~(~A1 | B1 | B2 | B3)"
    if cell.startswith(("XOR2",)):
        return out, "A1 ^ A2"
    if cell.startswith(("XNR2",)):
        return out, "~(A1 ^ A2)"
    if cell.startswith(("XOR3",)):
        return out, "A1 ^ A2 ^ A3"
    if cell.startswith(("XNR3",)):
        return out, "~(A1 ^ A2 ^ A3)"
    if cell.startswith(("XOR4",)):
        return out, "A1 ^ A2 ^ A3 ^ A4"
    if cell.startswith(("XNR4",)):
        return out, "~(A1 ^ A2 ^ A3 ^ A4)"
    if cell.startswith("MUX2") and out == "Z":
        return out, "S ? I1 : I0"
    if cell.startswith("MUX2") and out == "ZN":
        return out, "~(S ? I1 : I0)"
    if cell.startswith("MAOI222"):
        return out, "~((A & B) | (A & C) | (B & C))"
    if cell.startswith("MAOI22"):
        return out, "~((A1 & A2) | (B1 & B2))"
    if cell.startswith("MOAI22"):
        return out, "~((A1 | A2) & (B1 | B2))"
    if cell.startswith("TIEH"):
        return out, "1'b1"
    if cell.startswith("TIEL"):
        return out, "1'b0"
    return out, "1'bx"


def emit_flop_initial(out_lines: list[str], ports: list[str]) -> None:
    has_q = "Q" in ports
    has_qn = "QN" in ports
    if not (has_q or has_qn):
        return

    out_lines.append("  `ifdef RANDOMIZE_REG_INIT")
    out_lines.append("    initial begin")
    if has_q:
        out_lines.append("      Q = $random;")
    if has_qn:
        if has_q:
            out_lines.append("      QN = ~Q;")
        else:
            out_lines.append("      QN = $random;")
    out_lines.append("    end")
    out_lines.append("  `endif")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--netlist", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    text = Path(args.netlist).read_text(errors="ignore")
    cells: dict[str, list[str]] = {}
    for match in re.finditer(r"^\s*([A-Za-z0-9_]+BWP40P140)\s+\S+\s*\((.*?)\);",
                             text, re.MULTILINE | re.DOTALL):
        cell = match.group(1)
        ports = re.findall(r"\.([A-Za-z0-9_]+)\s*\(", match.group(2))
        if cell not in cells:
            cells[cell] = []
        for port in ports:
            if port not in cells[cell]:
                cells[cell].append(port)

    out_lines = [
        "`timescale 1ns/1ps",
        "// Auto-generated zero-delay functional models for the BWP40P140 cells",
        "// actually used by the synthesized accelerator netlist.",
        "",
    ]

    for cell in sorted(cells):
        ports = cells[cell]
        decls = []
        for port in ports:
            direction = "output" if port in {"Z", "ZN", "Q", "QN", "S", "CO"} else "input"
            decls.append(f"  {direction} {port};")
        out_lines.append(f"module {cell} ({', '.join(ports)});")
        out_lines.extend(decls)

        if cell.startswith("DFM"):
            if "Q" in ports:
                out_lines.append("  reg Q;")
            if "QN" in ports:
                out_lines.append("  reg QN;")
            emit_flop_initial(out_lines, ports)
            if "Q" in ports:
                out_lines.append("  always @(posedge CP) Q <= SA ? DB : DA;")
            if "QN" in ports:
                out_lines.append("  always @(posedge CP) QN <= ~(SA ? DB : DA);")
        elif cell.startswith(("EDF", "EDFQ")):
            if "Q" in ports:
                out_lines.append("  reg Q;")
            if "QN" in ports:
                out_lines.append("  reg QN;")
            emit_flop_initial(out_lines, ports)
            if "Q" in ports and "QN" in ports:
                out_lines.append("  always @(posedge CP) if (E) begin Q <= D; QN <= ~D; end")
            elif "Q" in ports:
                out_lines.append("  always @(posedge CP) if (E) Q <= D;")
            elif "QN" in ports:
                out_lines.append("  always @(posedge CP) if (E) QN <= ~D;")
        elif cell.startswith("DFK"):
            if "Q" in ports:
                out_lines.append("  reg Q;")
            if "QN" in ports:
                out_lines.append("  reg QN;")
            emit_flop_initial(out_lines, ports)
            out_lines.append("  always @(posedge CP or negedge SN or negedge CN) begin")
            out_lines.append("    if (!SN) begin")
            if "Q" in ports:
                out_lines.append("      Q <= 1'b1;")
            if "QN" in ports:
                out_lines.append("      QN <= 1'b0;")
            out_lines.append("    end else if (!CN) begin")
            if "Q" in ports:
                out_lines.append("      Q <= 1'b0;")
            if "QN" in ports:
                out_lines.append("      QN <= 1'b1;")
            out_lines.append("    end else begin")
            if "Q" in ports:
                out_lines.append("      Q <= D;")
            if "QN" in ports:
                out_lines.append("      QN <= ~D;")
            out_lines.append("    end")
            out_lines.append("  end")
        elif cell.startswith(("DFQ", "DFD")):
            if "Q" in ports:
                out_lines.append("  reg Q;")
            if "QN" in ports:
                out_lines.append("  reg QN;")
            emit_flop_initial(out_lines, ports)
            if "Q" in ports and "QN" in ports:
                out_lines.append("  always @(posedge CP) begin Q <= D; QN <= ~D; end")
            elif "Q" in ports:
                out_lines.append("  always @(posedge CP) Q <= D;")
            elif "QN" in ports:
                out_lines.append("  always @(posedge CP) QN <= ~D;")
        elif cell.startswith("FA1"):
            if "CO" in ports:
                out_lines.append("  assign {CO, S} = A + B + CI;")
            else:
                out_lines.append("  assign S = A ^ B ^ CI;")
        elif cell.startswith("HA1"):
            if "CO" in ports:
                out_lines.append("  assign {CO, S} = A + B;")
            else:
                out_lines.append("  assign S = A ^ B;")
        else:
            out_port, expr = gate_expr(cell, ports)
            out_lines.append(f"  assign {out_port} = {expr};")
        out_lines.append("endmodule")
        out_lines.append("")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(out_lines))
    print(f"wrote {out} with {len(cells)} cell models")


if __name__ == "__main__":
    main()
