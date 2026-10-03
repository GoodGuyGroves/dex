"""Summarise the current review loop for `dx review status` and the Phase 3 wait.

The caller resolves the run's events.jsonl and the Phase 3 busy record (bash
validates that record; see __dx_phase_busy_record) and passes them in. This
script only reads and formats, so a missing, partial or malformed journal
degrades to less detail rather than an error.

Formats:
  text  a few lines for a person at a terminal
  json  the same facts as one JSON object
  line  one line for the Stop hook's systemMessage, or nothing when there is
        no review pass it can name; the hook then keeps its own fallback text.
        With --finished-wave N and no wave running, it prints only wave N's
        result: the review loop clears the busy record before it journals the
        wave's result, so the hook waits for that wave rather than reporting
        the one before it.
"""

import argparse
import json
import re
import sys
import time

TIER_EVENTS = {"review.tier.selected", "review.tier.escalated", "review.tier.deescalated"}
END_EVENTS = {"review.completed", "review.paused"}
LABEL_PATTERN = re.compile(r"^Wave (\d+) · (.+?) · (\d+)/(\d+) clean$")
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def format_duration(seconds):
    """Mirror lib/output.sh dx_format_duration."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def whole(value):
    """A non-negative int from a journal field, or None."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def text_field(value):
    """Journal text as one printable line. It ends up in the pane through the
    Stop hook's systemMessage, so control characters (terminal escapes
    included) become spaces."""
    if not isinstance(value, str):
        return ""
    return CONTROL_CHARACTERS.sub(" ", value).strip()[:120]


def event_name(event):
    for field in ("type", "name"):
        value = event.get(field)
        if isinstance(value, str) and value:
            return value
    return ""


def read_events(path):
    """Yield (name, data) for each well-formed journal line."""
    if not path:
        return
    try:
        stream = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return
    with stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            data = event.get("data")
            yield event_name(event), (data if isinstance(data, dict) else {})


def latest_loop(path):
    """The last review loop in the journal. A resumed loop re-emits
    review.tier.selected into the same journal, so a selection only opens a
    new loop after the previous one completed or paused (as review_stats.py
    counts them)."""
    loop = None
    for name, data in read_events(path):
        if not name.startswith("review."):
            continue
        if loop is None or (loop["outcome"] and name == "review.tier.selected"):
            loop = {"tier": "", "profile": "", "required_clean": None,
                    "max_waves": None, "waves": [], "started": None,
                    "outcome": None}
        if name in TIER_EVENTS or name == "review.pass.started":
            loop["tier"] = text_field(data.get("tier")) or loop["tier"]
            loop["profile"] = text_field(data.get("profile")) or loop["profile"]
        for field in ("required_clean", "max_waves"):
            value = whole(data.get(field))
            if value is not None and name != "review.pass.finished":
                loop[field] = value
        if name == "review.pass.started":
            loop["started"] = {
                "wave": whole(data.get("iteration")),
                "clean_before": whole(data.get("clean_before")),
            }
        elif name == "review.pass.finished":
            loop["waves"].append({
                "wave": whole(data.get("iteration")),
                "result": text_field(data.get("result_kind")) or "unknown",
                "reason": text_field(data.get("result_reason")),
                "findings": whole(data.get("findings")),
                "clean_after": whole(data.get("clean_after")),
                "duration_seconds": whole(data.get("duration_seconds")),
            })
            loop["started"] = None
        elif name in END_EVENTS:
            loop["outcome"] = {
                "kind": "completed" if name == "review.completed" else "paused",
                "reason": text_field(data.get("reason")),
            }
    return loop


def verdict(wave):
    result, findings = wave["result"], wave["findings"]
    if result == "clean":
        return "CLEAN"
    if result in ("notes", "deescalate"):
        return f"CLEAN ({result})"
    if result == "findings_fixed":
        return f"FIXED {findings}" if findings is not None else "FIXED"
    if result == "findings":
        return f"FINDINGS {findings}" if findings is not None else "FINDINGS"
    label = result.upper()
    if wave["reason"] and wave["reason"] != "none":
        label += f" ({wave['reason']})"
    return label


def current_pass(loop, busy, now):
    """The running wave, from the busy record first: its label is what the
    review child updates as it moves through stages."""
    if busy is None:
        return None
    current = {"wave": None, "stage": busy["label"], "clean": None,
               "required_clean": None, "elapsed_seconds": max(0, now - busy["epoch"]),
               "timeout_seconds": busy["timeout"] or None}
    match = LABEL_PATTERN.match(busy["label"])
    if match:
        current["wave"] = int(match.group(1))
        current["stage"] = match.group(2)
        current["clean"] = int(match.group(3))
        current["required_clean"] = int(match.group(4))
    if loop and loop["started"]:
        if current["wave"] is None:
            current["wave"] = loop["started"]["wave"]
        if current["clean"] is None:
            current["clean"] = loop["started"]["clean_before"]
    if loop and current["required_clean"] is None:
        current["required_clean"] = loop["required_clean"]
    return current


def wave_of(loop, number):
    if number is None:
        return "Wave ?"
    if loop and loop["max_waves"]:
        return f"Wave {number}/{loop['max_waves']}"
    return f"Wave {number}"


def clean_of(clean, required):
    if clean is None:
        return None
    return f"{clean}/{required} clean" if required else f"{clean} clean"


def running_line(loop, current):
    parts = [wave_of(loop, current["wave"])]
    if loop and loop["tier"]:
        parts.append(loop["tier"])
    parts.append(current["stage"])
    clean = clean_of(current["clean"], current["required_clean"])
    if clean:
        parts.append(clean)
    elapsed = format_duration(current["elapsed_seconds"])
    if current["timeout_seconds"]:
        parts.append(f"{elapsed}/{format_duration(current['timeout_seconds'])}")
    else:
        parts.append(f"{elapsed} elapsed")
    return " · ".join(parts)


def finished_line(loop, wave):
    parts = [wave_of(loop, wave["wave"]), verdict(wave)]
    clean = clean_of(wave["clean_after"], loop["required_clean"])
    if clean:
        parts.append(clean)
    if wave["duration_seconds"] is not None:
        parts.append(format_duration(wave["duration_seconds"]))
    if loop["outcome"]:
        if loop["outcome"]["kind"] == "completed" and loop["outcome"]["reason"] == "clean_gate_reached":
            parts.append("clean gate reached")
        else:
            reason = loop["outcome"]["reason"]
            parts.append(f"{loop['outcome']['kind']}{' (' + reason + ')' if reason else ''}")
    return " · ".join(parts)


def summary(loop, current):
    return {
        "tier": loop["tier"] if loop else "",
        "profile": loop["profile"] if loop else "",
        "required_clean": loop["required_clean"] if loop else None,
        "max_waves": loop["max_waves"] if loop else None,
        "current": current,
        "waves": [dict(wave, verdict=verdict(wave)) for wave in loop["waves"]] if loop else [],
        "outcome": loop["outcome"] if loop else None,
    }


def render_text(loop, current):
    if not loop and not current:
        return ["No review pass recorded."]
    lines = []
    if loop and loop["tier"]:
        head = f"Review tier: {loop['tier']}"
        if loop["profile"]:
            head += f" ({loop['profile']})"
        if loop["required_clean"]:
            head += f" · {loop['required_clean']} consecutive clean waves required"
        if loop["max_waves"]:
            head += f" · budget {loop['max_waves']} waves"
        lines.append(head)
    if current:
        lines.append(f"Running: {running_line(loop, current)}")
    if loop and loop["waves"]:
        lines.append("Finished waves:")
        for wave in loop["waves"]:
            row = f"  {wave_of(loop, wave['wave'])} · {verdict(wave)}"
            clean = clean_of(wave["clean_after"], loop["required_clean"])
            if clean:
                row += f" · {clean}"
            if wave["duration_seconds"] is not None:
                row += f" · {format_duration(wave['duration_seconds'])}"
            lines.append(row)
    if loop and loop["outcome"]:
        reason = loop["outcome"]["reason"]
        lines.append(f"Outcome: {loop['outcome']['kind']}{' (' + reason + ')' if reason else ''}")
    elif not current:
        lines.append("No wave is running.")
    return lines


def main(argv):
    parser = argparse.ArgumentParser(description="Summarise the current review loop.")
    parser.add_argument("--format", choices=("text", "json", "line"), default="text")
    parser.add_argument("--events", default="")
    parser.add_argument("--busy-epoch", default="")
    parser.add_argument("--busy-timeout", default="")
    parser.add_argument("--busy-label", default="")
    parser.add_argument("--now", default="")
    parser.add_argument("--finished-wave", default="")
    args = parser.parse_args(argv)

    now = int(args.now) if args.now.isdigit() else int(time.time())
    busy = None
    if args.busy_epoch.isdigit() and args.busy_label:
        busy = {"epoch": int(args.busy_epoch), "label": text_field(args.busy_label),
                "timeout": int(args.busy_timeout) if args.busy_timeout.isdigit() else 0}

    loop = latest_loop(args.events)
    if loop and not (loop["tier"] or loop["waves"] or loop["started"] or loop["outcome"]):
        loop = None
    current = current_pass(loop, busy, now)

    if args.format == "json":
        print(json.dumps(summary(loop, current), sort_keys=True))
    elif args.format == "line":
        if current:
            # A line that cannot name its wave tells the reader nothing the
            # hook's own text does not, so say nothing and let it stand.
            if current["wave"] is not None:
                print(running_line(loop, current))
        elif loop and loop["waves"]:
            last = loop["waves"][-1]
            wanted = int(args.finished_wave) if args.finished_wave.isdigit() else None
            if wanted is None or last["wave"] == wanted:
                print(finished_line(loop, last))
    else:
        print("\n".join(render_text(loop, current)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
