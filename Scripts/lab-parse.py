#!/usr/bin/env python3
"""Summarises a lab-heaven.sh result folder into results.json.
Usage: python3 Scripts/lab-parse.py <result folder>

Per run it reads:
  <name>.syslog   `log stream` of subsystem com.apple.metal.hud. Each `metal-HUD:` line is
                  <first-frame>,<memory or frame-misses>,<process-memory>,then (present-interval, gpu-time)
                  pairs for the frames of that second (Apple's documented format).
  <name>.log      Wine's output: lab exit/timeout markers, DLL loads, renderer warnings.
  <name>.thermal  `pmset -g therm` samples.
FPS = 1000 / mean(present interval); the 1% low uses the 99th-percentile interval.
"Steady" drops the first 60 s, which is loading and shader compilation."""
import json, os, re, sys
from datetime import datetime
from statistics import mean, median

STEADY_AFTER = 60.0

def percentile(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]

def stats(frames):
    if not frames:
        return None
    present = [f[0] for f in frames]
    gpu = [f[1] for f in frames]
    return {
        "frames": len(frames),
        "avg_fps": round(1000 / mean(present), 2),
        "low1_fps": round(1000 / percentile(present, 99), 2),
        "median_present_ms": round(median(present), 2),
        "median_gpu_ms": round(median(gpu), 2),
        # Share of a frame the GPU was busy. Low means the bottleneck is elsewhere (CPU, sync, pacing).
        "gpu_busy": round(median(gpu) / median(present), 2) if median(present) else None,
    }

def hud_lines(path):
    """Returns [(seconds since first line, [numeric fields])], one entry per HUD line.
    The unified log redacts the per-frame part as <private> unless private data logging is on,
    so the list can stop after the first three fields."""
    lines, start, seen = [], None, set()
    if not os.path.exists(path):
        return lines
    for line in open(path, encoding="utf-8", errors="replace"):
        if "metal-HUD:" not in line:
            continue
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
        t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() if m else 0.0
        payload = line.split("metal-HUD:", 1)[1].replace("<private>", "").strip()
        if (t, payload) in seen:  # the same event is printed once per log source
            continue
        seen.add((t, payload))
        start = t if start is None else start
        nums = []
        for f in payload.split(","):
            try:
                nums.append(float(f))
            except ValueError:
                break
        if nums:
            lines.append((t - start, nums))
    return lines

def hud_frames(lines):
    """Per-frame (seconds, present ms, gpu ms) from the unredacted fields, if any."""
    frames = []
    for t, nums in lines:
        pairs = nums[3:]
        for i in range(0, len(pairs) - 1, 2):
            frames.append((t, pairs[i], pairs[i + 1]))
    # Intervals logged in seconds rather than milliseconds on some macOS versions.
    if frames and median(f[1] for f in frames) < 1.0:
        frames = [(t, p * 1000, g * 1000) for t, p, g in frames]
    return frames

def counter_stats(lines, after=0.0):
    """FPS from the first field (frame number) between HUD lines: works when per-frame data is redacted.
    The "1% low" here is the slowest one-second window, the closest this data gets."""
    # Frame number 0 shows up between real lines (a second, idle surface or a counter reset), not as a freeze.
    pts = [(t, nums[0]) for t, nums in lines if t >= after and nums[0] > 0]
    rates = []
    for (t0, f0), (t1, f1) in zip(pts, pts[1:]):
        if t1 > t0 and f1 >= f0:
            rates.append(((f1 - f0) / (t1 - t0), t1 - t0))
    if not rates:
        return None
    frames, seconds = pts[-1][1] - pts[0][1], pts[-1][0] - pts[0][0]
    # A window longer than 2 s, or one where the counter did not move, is a freeze (shader compiles,
    # scene loads): it drags the average down while the typical second runs much faster.
    stalls = [dt for r, dt in rates if r == 0 or dt > 2.0]
    return {
        "frames": int(frames),
        "avg_fps": round(frames / seconds, 2) if seconds else None,
        "typical_fps": round(median(r for r, _ in rates), 2),
        "low1_fps": round(min(r for r, _ in rates), 2),
        "stalls": len(stalls),
        "stall_seconds": round(sum(stalls), 1),
        "longest_stall_s": round(max(stalls), 1) if stalls else 0.0,
        "median_present_ms": None,
        "median_gpu_ms": None,
        "gpu_busy": None,
        "source": "frame-counter",
    }

def run_summary(folder, name):
    log = open(os.path.join(folder, f"{name}.log"), encoding="utf-8", errors="replace").read()
    exit_m = re.search(r"GAMEPORT_LAB: exit=(\d+) seconds=(\d+)", log)
    seconds = int(exit_m.group(2)) if exit_m else None
    lines = hud_lines(os.path.join(folder, f"{name}.syslog"))
    frames = hud_frames(lines)
    thermal_path = os.path.join(folder, f"{name}.thermal")
    thermal = open(thermal_path).read() if os.path.exists(thermal_path) else ""
    levels = [int(x) for x in re.findall(r"(?:Thermal|Performance) Warning Level\D*(\d+)", thermal)]
    return {
        "run": name,
        "seconds": seconds,
        "exit": int(exit_m.group(1)) if exit_m else None,
        "timed_out": "GAMEPORT_LAB: timeout" in log,
        "likely_crash": seconds is not None and seconds < 60 and "GAMEPORT_LAB: timeout" not in log,
        "dxmt_loaded": "winemetal.dll" in log,
        "dxvk_loaded": "DXVK" in log,
        # "DXVK-Kegworks: v1.10.4-async" (engine) or "DXVK: v1.10.3-… + GamePort query fix" (Scripts/build-dxvk.sh)
        "dxvk_version": (re.search(r"DXVK[\w-]*: (v1\.[^\n]*)", log) or [None, None])[1],
        "unsupported_query_types": log.count("is not supported, results will be zero"),
        "tess_clamp_warnings": log.count("is too large for a mesh pipeline"),
        "errors": sorted(set(re.findall(r"(?:err:\S*|\[mvk-error\])[^\n]{0,160}", log)))[:10],
        "hud_lines_found": len(lines),
        "per_frame_data": bool(frames),
        "all": stats([(p, g) for _, p, g in frames]) or counter_stats(lines),
        "steady": stats([(p, g) for t, p, g in frames if t >= STEADY_AFTER]) or counter_stats(lines, STEADY_AFTER),
        "max_thermal_warning_level": max(levels) if levels else None,
    }

def main():
    folder = sys.argv[1]
    names = sorted(f[:-4] for f in os.listdir(folder) if f.endswith(".log"))
    results = [run_summary(folder, n) for n in names]
    with open(os.path.join(folder, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    for r in results:
        s = r["steady"] or r["all"]
        if not s:
            fps = "no FPS"
        elif s.get("source") == "frame-counter":
            fps = (f"typical {s['typical_fps']} FPS, average {s['avg_fps']}, "
                   f"{s['stalls']} stalls / {s['stall_seconds']} s (longest {s['longest_stall_s']} s), from the frame counter")
        else:
            fps = f"{s['avg_fps']} FPS (1% {s['low1_fps']}), GPU {s['median_gpu_ms']} ms"
        flag = "CRASHED?" if r["likely_crash"] else ("timed out" if r["timed_out"] else "finished")
        print(f"  {r['run']:<16} {flag:<10} {fps}")

if __name__ == "__main__":
    main()
