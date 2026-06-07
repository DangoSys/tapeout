#!/usr/bin/env python3
import argparse


SIGNALS = {
    "ref": {
        "clock": "+",
        "reset": '"',
        "ar_ready": "A",
        "ar_valid": "B",
        "ar_addr": "/",
        "ar_len": "0",
        "ar_size": "1",
        "r_ready": "C",
        "r_valid": "D",
        "r_data": "F",
        "r_last": "G",
        "aw_ready": "-",
        "aw_valid": ".",
        "aw_addr": "/",
        "aw_len": "0",
        "aw_size": "1",
        "w_ready": "8",
        "w_valid": "9",
        "w_data": ":",
        "w_strb": "<",
        "w_last": ";",
        "b_ready": "=",
        "b_valid": ">",
        "b_resp": "?",
        "b_id": "@",
        "initialized": "I",
    },
    "gls": {
        "clock": "+",
        "reset": '"',
        "ar_ready": "4",
        "ar_valid": "I",
        "ar_addr": "K",
        "ar_len": "L",
        "ar_size": "M",
        "r_ready": "S",
        "r_valid": "5",
        "r_data": "7",
        "r_last": "9",
        "aw_ready": "/",
        "aw_valid": ":",
        "aw_addr": "<",
        "aw_len": "=",
        "aw_size": ">",
        "w_ready": "0",
        "w_valid": "D",
        "w_data": "E",
        "w_strb": "F",
        "w_last": "G",
        "b_ready": "H",
        "b_valid": "1",
        "b_resp": "3",
        "b_id": "2",
        "initialized": None,
    },
}


def as_int(value):
    if value is None:
        return None
    if any(c in value.lower() for c in "xz"):
        return value
    return int(value, 2)


def fmt(value, width=None):
    value = as_int(value)
    if value is None:
        return "-"
    if isinstance(value, str):
        return value
    if width is None:
        return str(value)
    return f"0x{value:0{width}x}"


def parse_changes(line):
    line = line.strip()
    if not line:
        return None
    if line[0] in "01xXzZ":
        return line[1:], line[0].lower()
    if line[0] in "bB":
        value, code = line[1:].split(None, 1)
        return code, value.lower()
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("vcd")
    parser.add_argument("--kind", choices=SIGNALS, required=True)
    parser.add_argument("--channel", choices=("read", "write", "both"), default="read")
    parser.add_argument("--limit", type=int, default=80)
    parser.add_argument("--start", type=int, default=0)
    args = parser.parse_args()

    sig = SIGNALS[args.kind]
    wanted = {code for code in sig.values() if code is not None}
    values = {code: None for code in wanted}
    time = 0
    in_defs = True
    last_clock = None
    cycle = -1
    printed = 0
    prev_ar_fire = False
    prev_r_fire = False
    prev_aw_fire = False
    prev_w_fire = False
    prev_b_fire = False

    with open(args.vcd, "r", errors="ignore") as f:
        for raw in f:
            if in_defs:
                if raw.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if raw.startswith("#"):
                clock = values.get(sig["clock"])
                if clock == "1" and last_clock == "0":
                    cycle += 1
                    ar_fire = values.get(sig["ar_valid"]) == "1" and values.get(sig["ar_ready"]) == "1"
                    r_fire = values.get(sig["r_valid"]) == "1" and values.get(sig["r_ready"]) == "1"
                    aw_fire = values.get(sig["aw_valid"]) == "1" and values.get(sig["aw_ready"]) == "1"
                    w_fire = values.get(sig["w_valid"]) == "1" and values.get(sig["w_ready"]) == "1"
                    b_fire = values.get(sig["b_valid"]) == "1" and values.get(sig["b_ready"]) == "1"
                    show_read = (
                        args.channel in ("read", "both")
                        and ((ar_fire and not prev_ar_fire) or r_fire or cycle < 12)
                    )
                    show_write = (
                        args.channel in ("write", "both")
                        and ((aw_fire and not prev_aw_fire) or w_fire or b_fire)
                    )
                    if cycle >= args.start and (show_read or show_write):
                        if show_read:
                            print(
                                f"t={time:<12} cyc={cycle:<6} R "
                                f"rst={values.get(sig['reset'])} "
                                f"init={values.get(sig['initialized'], '-')} "
                                f"ar={values.get(sig['ar_valid'])}/{values.get(sig['ar_ready'])} "
                                f"addr={fmt(values.get(sig['ar_addr']), 8)} "
                                f"len={fmt(values.get(sig['ar_len']))} "
                                f"sz={fmt(values.get(sig['ar_size']))} "
                                f"r={values.get(sig['r_valid'])}/{values.get(sig['r_ready'])} "
                                f"last={values.get(sig['r_last'])} "
                                f"data={fmt(values.get(sig['r_data']), 16)}"
                            )
                            printed += 1
                        if show_write:
                            print(
                                f"t={time:<12} cyc={cycle:<6} W "
                                f"rst={values.get(sig['reset'])} "
                                f"aw={values.get(sig['aw_valid'])}/{values.get(sig['aw_ready'])} "
                                f"addr={fmt(values.get(sig['aw_addr']), 8)} "
                                f"len={fmt(values.get(sig['aw_len']))} "
                                f"sz={fmt(values.get(sig['aw_size']))} "
                                f"w={values.get(sig['w_valid'])}/{values.get(sig['w_ready'])} "
                                f"last={values.get(sig['w_last'])} "
                                f"strb={fmt(values.get(sig['w_strb']), 2)} "
                                f"data={fmt(values.get(sig['w_data']), 16)} "
                                f"b={values.get(sig['b_valid'])}/{values.get(sig['b_ready'])} "
                                f"bid={fmt(values.get(sig['b_id']))} "
                                f"resp={fmt(values.get(sig['b_resp']))}"
                            )
                            printed += 1
                        if printed >= args.limit:
                            return
                    prev_ar_fire = ar_fire
                    prev_r_fire = r_fire
                    prev_aw_fire = aw_fire
                    prev_w_fire = w_fire
                    prev_b_fire = b_fire
                last_clock = clock
                time = int(raw[1:])
                continue

            change = parse_changes(raw)
            if change is None:
                continue
            code, value = change
            if code in wanted:
                values[code] = value


if __name__ == "__main__":
    main()
