#!/usr/bin/env python3
"""Measure a running helper and its descendant processes; retain numeric samples only."""
import argparse
import json
import math
import subprocess
import time
from pathlib import Path


MINIMUM_OBSERVATION_SECONDS = 30 * 60
MAXIMUM_AVERAGE_CPU_PERCENT = 2.0
MAXIMUM_AVERAGE_RSS_MIB = 150.0


def seconds(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    result = 0.0
    for piece in value.split(":"):
        result = result * 60 + float(piece)
    return days * 86400 + result


def validate_arguments(parser, arguments):
    if not math.isfinite(arguments.duration) or arguments.duration <= 0:
        parser.error("--duration must be a finite positive number of seconds")
    if not math.isfinite(arguments.interval) or arguments.interval <= 0:
        parser.error("--interval must be a finite positive number of seconds")


def result_for(samples, survived, elapsed, cpu_seconds):
    average_cpu_percent = cpu_seconds / max(elapsed, 1.0) * 100
    average_rss_mib = sum(sample["rssMiB"] for sample in samples) / max(1, len(samples))
    child_process_samples = sum(sample["processes"] > 1 for sample in samples)
    resource_budget_passed = (
        survived
        and elapsed >= MINIMUM_OBSERVATION_SECONDS
        and average_cpu_percent < MAXIMUM_AVERAGE_CPU_PERCENT
        and average_rss_mib < MAXIMUM_AVERAGE_RSS_MIB
    )
    # Numeric process sampling cannot establish a connected backend or ten watched tasks.
    workload_verified = False
    acceptance_passed = resource_budget_passed and workload_verified
    return {
        "durationSeconds": elapsed,
        "survived": survived,
        "sampleCount": len(samples),
        "averageCPUPercent": average_cpu_percent,
        "averageRSSMiB": average_rss_mib,
        "peakRSSMiB": max((sample["rssMiB"] for sample in samples), default=0),
        "peakProcesses": max((sample["processes"] for sample in samples), default=0),
        "childProcessSamples": child_process_samples,
        "childProcessSampleCoveragePercent": child_process_samples / max(1, len(samples)) * 100,
        "resourceBudgetPassed": resource_budget_passed,
        "workloadVerified": workload_verified,
        "acceptancePassed": acceptance_passed,
        "measurement": "Sampled full process tree; very short-lived processes between samples may be missed. Numeric sampling alone cannot verify a healthy backend or ten watched tasks.",
        "samples": samples,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--duration", type=float, default=MINIMUM_OBSERVATION_SECONDS)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    validate_arguments(parser, arguments)

    start = time.monotonic()
    previous = {}
    cpu_seconds = 0.0
    samples = []
    survived = True
    while True:
        output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,time=,rss="], text=True)
        rows = {}
        for line in output.splitlines():
            values = line.split()
            if len(values) == 4:
                pid, parent = int(values[0]), int(values[1])
                rows[pid] = (parent, seconds(values[2]), int(values[3]))
        if arguments.pid not in rows:
            survived = False
            break
        included = {arguments.pid}
        while True:
            added = {pid for pid, row in rows.items() if row[0] in included}
            if added <= included:
                break
            included.update(added)
        current = {pid: rows[pid][1] for pid in included}
        if samples:
            cpu_seconds += sum(max(0, value - previous.get(pid, 0)) for pid, value in current.items())
        previous = current
        elapsed = time.monotonic() - start
        samples.append({
            "seconds": round(elapsed, 2),
            "rssMiB": sum(rows[pid][2] for pid in included) / 1024,
            "processes": len(included),
        })
        if elapsed >= arguments.duration:
            break
        time.sleep(min(arguments.interval, max(0, arguments.duration - elapsed)))

    result = result_for(samples, survived, time.monotonic() - start, cpu_seconds)
    # No process arguments, paths, task names, or payloads are recorded.
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}, indent=2))


if __name__ == "__main__":
    main()
