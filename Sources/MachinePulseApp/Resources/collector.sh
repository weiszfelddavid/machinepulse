#!/bin/sh
# MachinePulse's agentless collector for Linux and macOS. It reads standard
# kernel and system interfaces, emits one JSON document, and does not write to
# the remote host.
if [ "$(uname -s)" = Darwin ] && [ "$(command -v python3)" = /usr/bin/python3 ] \
    && ! xcode-select -p >/dev/null 2>&1; then
    echo "python3 needs the Command Line Tools on this Mac (xcode-select --install)." >&2
    exit 2
fi
exec python3 - <<'PY'
import json
import base64
import ctypes
import ipaddress
import math
import os
import plistlib
import re
import socket
import subprocess
import sys
import time
import xml.parsers.expat

LINUX_COLLECTOR_VERSION = "linux-agentless-v6"
DARWIN_COLLECTOR_VERSION = "mac-agentless-v1"
DARWIN_HOST_CPU_LOAD_INFO = 3
DARWIN_SYSCTL_KEYS = [
    "hw.memsize", "hw.ncpu", "kern.boottime", "kern.bootsessionuuid",
    "kern.memorystatus_vm_pressure_level", "vm.swapusage",
]
IO_AUDIT_MINIMUM_AVERAGE_10 = 5.0
MAX_EXPECTED_UNITS = 12
MAX_OOM_JOURNAL_ROWS = 256
MAX_LISTENER_ROWS = 128
MAX_REMOTE_WORKLOADS = 16
MAX_LISTENERS_PER_WORKLOAD = 4
MAX_RESOURCE_CONTROLS = 16
MAX_RESOURCE_CANDIDATES_PER_SORT = 8
MAX_CGROUP_FILE_BYTES = 8_192
IGNORED_WORKLOAD_PROCESSES = {
    "chrome", "chromium", "firefox", "google-chrome", "sshd", "systemd-resolve", "tailscaled",
}
IGNORED_WORKLOAD_UNITS = {
    "ssh.service", "sshd.service", "systemd-networkd.service",
    "systemd-resolved.service", "systemd-timesyncd.service", "tailscaled.service",
}
RESOURCE_SCOPE_PROCESSES = {
    "chrome", "chromium", "firefox", "google-chrome",
    "aider", "claude", "codex", "cursor", "gemini", "hermes", "node", "openclaw",
}


def number(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return default


def root_device_identity():
    try:
        device = os.stat("/").st_dev
        return f"dev:{os.major(device)}:{os.minor(device)}"
    except OSError:
        return None


def root_filesystem_identity():
    try:
        result = subprocess.run(
            ["findmnt", "-n", "-o", "UUID", "/"],
            capture_output=True, text=True, timeout=2, check=False,
        )
        value = result.stdout.strip()
        if value and len(value) <= 128 and re.fullmatch(r"[A-Za-z0-9._:-]+", value):
            return "uuid:" + value
    except (OSError, subprocess.TimeoutExpired):
        pass
    return root_device_identity()


def cpu_ticks():
    fields = read_text("/proc/stat").splitlines()[0].split()[1:]
    values = [int(value) for value in fields]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def process_io_counters():
    counters = {}
    try:
        entries = os.scandir("/proc")
    except OSError:
        return counters
    with entries:
        for entry in entries:
            if not entry.name.isdigit():
                continue
            values = {}
            for line in read_text(entry.path + "/io").splitlines():
                if ":" in line:
                    key, raw = line.split(":", 1)
                    try:
                        values[key] = int(raw.strip())
                    except ValueError:
                        continue
            if values:
                counters[int(entry.name)] = (
                    values.get("read_bytes", 0),
                    values.get("write_bytes", 0),
                )
    return counters


def process_cgroup_identity(pid):
    for line in read_text(f"/proc/{pid}/cgroup").splitlines():
        path = line.rsplit(":", 1)[-1]
        for component in reversed(path.split("/")):
            if component.endswith((".service", ".scope")):
                return bounded_text(path, 256), bounded_text(component, 128)
    return None, None


def process_unit(pid):
    return process_cgroup_identity(pid)[1]


def activity_sample(ticks, audit_io):
    total_before, idle_before = ticks()
    io_before = process_io_counters() if audit_io else {}
    started = time.monotonic()
    time.sleep(0.15)
    total_after, idle_after = ticks()
    io_after = process_io_counters() if audit_io else {}
    duration = max(time.monotonic() - started, 0.001)

    cpu_elapsed = total_after - total_before
    cpu = 0.0
    if cpu_elapsed > 0:
        cpu = round(100.0 * (1.0 - ((idle_after - idle_before) / cpu_elapsed)), 2)

    activity = []
    for pid, after in io_after.items():
        before = io_before.get(pid)
        if not before:
            continue
        read_rate = max(0, after[0] - before[0]) / duration
        write_rate = max(0, after[1] - before[1]) / duration
        if read_rate + write_rate <= 0:
            continue
        name = read_text(f"/proc/{pid}/comm").strip() or str(pid)
        activity.append({
            "name": name,
            "systemdUnit": process_unit(pid),
            "readBytesPerSecond": read_rate,
            "writeBytesPerSecond": write_rate,
        })
    activity.sort(
        key=lambda item: item["readBytesPerSecond"] + item["writeBytesPerSecond"],
        reverse=True,
    )
    return cpu, activity[:5]


def meminfo():
    values = {}
    for line in read_text("/proc/meminfo").splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        fields = raw.strip().split()
        if fields:
            values[key] = int(fields[0]) * 1024
    return values


def pressure(kind):
    result = {"someAverage10": 0.0, "fullAverage10": 0.0}
    for line in read_text("/proc/pressure/" + kind).splitlines():
        fields = line.split()
        if not fields:
            continue
        values = dict(field.split("=", 1) for field in fields[1:] if "=" in field)
        if fields[0] == "some":
            result["someAverage10"] = number(values.get("avg10"))
        elif fields[0] == "full":
            result["fullAverage10"] = number(values.get("avg10"))
    return result


def root_device_numbers():
    for line in read_text("/proc/self/mountinfo").splitlines():
        fields = line.split()
        if len(fields) > 5 and fields[4] == "/":
            try:
                major, minor = fields[2].split(":", 1)
                return int(major), int(minor)
            except (ValueError, IndexError):
                return None
    return None


def disk_totals():
    device = root_device_numbers()
    if not device:
        return 0, 0
    wanted_major, wanted_minor = device
    for line in read_text("/proc/diskstats").splitlines():
        fields = line.split()
        if len(fields) < 14:
            continue
        if int(fields[0]) == wanted_major and int(fields[1]) == wanted_minor:
            return int(fields[5]) * 512, int(fields[9]) * 512
    return 0, 0


def network_totals():
    received = 0
    transmitted = 0
    for line in read_text("/proc/net/dev").splitlines()[2:]:
        if ":" not in line:
            continue
        interface, raw = line.split(":", 1)
        if interface.strip() == "lo":
            continue
        fields = raw.split()
        if len(fields) >= 9:
            received += int(fields[0])
            transmitted += int(fields[8])
    return received, transmitted


def process_table():
    # The command name is emitted last because it may itself contain spaces
    # ("Web Content"); the numeric columns are parsed from the left and the
    # remainder of the line is the complete name.
    command = ["ps", "-eo", "pid=,pcpu=,rss=,comm="]
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=2, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    result = []
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 4:
            continue
        try:
            pid = int(fields[0])
            cpu_percent = float(fields[1])
            resident_kilobytes = int(fields[2])
        except ValueError:
            continue
        name = fields[3].strip()
        # float() accepts "nan" and "inf", which json.dumps would emit as
        # invalid JSON tokens; only finite non-negative values are usable.
        if pid <= 0 or not name or not math.isfinite(cpu_percent) \
                or cpu_percent < 0 or resident_kilobytes < 0:
            continue
        result.append({
            "pid": pid,
            "name": name,
            "cpuPercent": cpu_percent,
            "residentBytes": resident_kilobytes * 1024,
        })
    return result


def top_processes(table, value_key):
    ranked = sorted(table, key=lambda item: item[value_key], reverse=True)
    return [
        {"name": item["name"], "cpuPercent": item["cpuPercent"], "residentBytes": item["residentBytes"]}
        for item in ranked[:5]
    ]


def failed_services():
    command = ["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"]
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=2, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    names = [line.split(None, 1)[0] for line in output.splitlines()[:20] if line.strip()]
    rows = [{"name": name} for name in names]
    if not names:
        return rows

    details_command = [
        "systemctl", "show", "--no-pager",
        "--property=Id,UnitFileState,StateChangeTimestampMonotonic",
    ] + names
    try:
        details_output = subprocess.run(
            details_command, capture_output=True, text=True, timeout=2, check=False
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return rows

    boot_epoch = time.time() - host_uptime()
    details = {}
    for block in details_output.strip().split("\n\n"):
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if values.get("Id"):
            details[values["Id"]] = values
    for row in rows:
        values = details.get(row["name"], {})
        monotonic_microseconds = number(values.get("StateChangeTimestampMonotonic"))
        row["failedAt"] = (
            boot_epoch + monotonic_microseconds / 1_000_000
            if monotonic_microseconds > 0 else None
        )
        row["isEnabled"] = values.get("UnitFileState") in {
            "enabled", "enabled-runtime", "linked", "linked-runtime"
        }
    return rows


def expected_unit_specs():
    encoded = os.environ.get("MACHINEPULSE_EXPECTED_UNITS_B64", "")
    if not encoded:
        return []
    try:
        decoded = base64.b64decode(encoded, validate=True)
        values = json.loads(decoded.decode("utf-8"))
    except (ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
        return []
    if not isinstance(values, list):
        return []
    result = []
    seen = set()
    for value in values[:MAX_EXPECTED_UNITS]:
        if not isinstance(value, dict):
            continue
        name = str(value.get("name", ""))
        kind = str(value.get("kind", ""))
        if kind not in {"service", "timer"} or not name.endswith("." + kind):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.@:-]{1,128}", name) or name in seen:
            continue
        seen.add(name)
        result.append({"name": name, "kind": kind})
    return result


def expected_units():
    specifications = expected_unit_specs()
    if not specifications:
        return []
    command = [
        "systemctl", "show", "--no-pager",
        "--property=Id,LoadState,ActiveState,SubState",
    ] + [item["name"] for item in specifications]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not completed.stdout.strip():
        return None

    details = {}
    blocks = completed.stdout.strip().split("\n\n")
    for block in blocks:
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if values.get("Id"):
            details[values["Id"]] = values

    result = []
    for specification in specifications:
        values = details.get(specification["name"], {})
        load_state = values.get("LoadState", "not-found")
        active_state = values.get("ActiveState", "inactive")
        if load_state in {"not-found", "error"}:
            state = "missing"
        elif active_state == "failed":
            state = "failed"
        elif active_state == "active":
            state = "active"
        else:
            state = "inactive"
        substate = re.sub(r"\s+", " ", values.get("SubState", "")).strip()[:64] or None
        result.append({
            "name": specification["name"],
            "kind": specification["kind"],
            "state": state,
            "substate": substate,
        })
    return result


def bounded_text(value, maximum=128):
    return re.sub(r"\s+", " ", str(value or "")).strip()[:maximum] or None


def host_uptime():
    return number(read_text("/proc/uptime").split()[0] if read_text("/proc/uptime") else 0)


def parse_listener_endpoint(raw):
    value = str(raw or "").strip()
    if not value:
        return None
    if value.startswith("[") and "]:" in value:
        address, raw_port = value[1:].rsplit("]:", 1)
    elif ":" in value:
        address, raw_port = value.rsplit(":", 1)
    else:
        return None
    try:
        port = int(raw_port)
    except ValueError:
        return None
    if not 1 <= port <= 65_535:
        return None
    address = address.split("%", 1)[0].strip("[]") or "*"
    return bounded_text(address, 64), port


def listener_binding(address):
    normalized = str(address or "").lower()
    if normalized in {"*", "0.0.0.0", "::", "0:0:0:0:0:0:0:0"}:
        return "allInterfaces"
    if normalized == "localhost":
        return "loopback"
    try:
        parsed = ipaddress.ip_address(normalized)
    except ValueError:
        return "unknown"
    if parsed.is_loopback:
        return "loopback"
    if parsed in ipaddress.ip_network("100.64.0.0/10") \
            or parsed in ipaddress.ip_network("fd7a:115c:a1e0::/48"):
        return "tailnet"
    if parsed.is_global:
        return "publicAddress"
    if parsed.is_private or parsed.is_link_local:
        return "privateNetwork"
    return "unknown"


def workload_web_protocol(port, process_name, unit):
    if port in {443, 8443}:
        return "https"
    if port in {80, 8080}:
        return "http"
    if port not in {3000, 4000, 5000, 8000, 8001, 8888}:
        return None
    identity = " ".join(filter(None, [process_name, unit])).lower()
    hints = {
        "apache", "caddy", "django", "flask", "gunicorn", "httpd", "nginx",
        "node", "php", "puma", "rails", "symfony", "uvicorn", "web",
    }
    return "http" if any(hint in identity for hint in hints) else None


def process_listener_identity(process_blob):
    match = re.search(r'\(\("([^"\\]{1,128})",pid=(\d+)', str(process_blob or ""))
    if not match:
        return None, None
    return bounded_text(match.group(1), 128), int(match.group(2))


def process_uptime(pid):
    raw = read_text(f"/proc/{pid}/stat")
    closing = raw.rfind(")")
    if closing < 0:
        return None
    fields = raw[closing + 1:].split()
    if len(fields) <= 19:
        return None
    try:
        started_after_boot = int(fields[19]) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError):
        return None
    return max(0, host_uptime() - started_after_boot)


def parse_listening_workloads(output, unit_by_pid=None, uptime_by_pid=None):
    groups = {}
    unit_by_pid = {str(key): value for key, value in (unit_by_pid or {}).items()}
    uptime_by_pid = {str(key): value for key, value in (uptime_by_pid or {}).items()}
    for line in str(output or "").splitlines()[:MAX_LISTENER_ROWS]:
        fields = line.split(None, 5)
        if len(fields) < 5:
            continue
        endpoint = parse_listener_endpoint(fields[3])
        if not endpoint:
            continue
        address, port = endpoint
        process_name, pid = process_listener_identity(fields[5] if len(fields) > 5 else "")
        if port in {22, 53}:
            continue
        injected_unit = unit_by_pid.get(str(pid)) if pid is not None else None
        unit = bounded_text(injected_unit or (process_unit(pid) if pid is not None else None))
        if unit and not re.fullmatch(r"[A-Za-z0-9_.@:-]{1,128}\.(?:service|scope)", unit):
            unit = None
        if unit and (unit.endswith(".scope") or unit.startswith("user@")):
            unit = None
        if (process_name or "").lower() in IGNORED_WORKLOAD_PROCESSES \
                or unit in IGNORED_WORKLOAD_UNITS:
            continue
        key = f"unit:{unit}" if unit else (f"pid:{pid}" if pid is not None else f"listener:{address}:{port}")
        group = groups.setdefault(key, {
            "name": unit or process_name or f"Listener on port {port}",
            "processName": process_name,
            "systemdUnit": unit,
            "state": "active",
            "substate": "listening",
            "uptimeSeconds": None,
            "listeners": [],
        })
        injected_uptime = uptime_by_pid.get(str(pid)) if pid is not None else None
        uptime = number(injected_uptime, -1) if injected_uptime is not None else (
            process_uptime(pid) if pid is not None else None
        )
        if uptime is not None and uptime >= 0:
            group["uptimeSeconds"] = uptime
        listener = {
            "address": address,
            "port": port,
            "binding": listener_binding(address),
            "webProtocol": workload_web_protocol(port, process_name, unit),
        }
        if listener not in group["listeners"] and len(group["listeners"]) < MAX_LISTENERS_PER_WORKLOAD:
            group["listeners"].append(listener)

    result = []
    for group in groups.values():
        group["listeners"].sort(key=lambda item: (item["port"], item["address"]))
        first = group["listeners"][0]
        identity = group["systemdUnit"] or (
            f"{group['processName'] or 'unknown'}@{first['address']}:{first['port']}"
        )
        group["id"] = bounded_text(identity, 256)
        result.append(group)
    result.sort(key=lambda item: (item["name"].lower(), item["id"]))
    return result[:MAX_REMOTE_WORKLOADS]


def merge_expected_workloads(workloads, expected_metrics):
    result = list(workloads or [])
    indexed = {
        workload.get("systemdUnit"): workload
        for workload in result
        if workload.get("systemdUnit")
    }
    for metric in expected_metrics or []:
        if metric.get("kind") != "service":
            continue
        name = bounded_text(metric.get("name"))
        if not name:
            continue
        if name in indexed:
            indexed[name]["state"] = metric.get("state", "inactive")
            indexed[name]["substate"] = bounded_text(metric.get("substate"), 64)
            continue
        result.append({
            "id": name,
            "name": name,
            "processName": None,
            "systemdUnit": name,
            "state": metric.get("state", "inactive"),
            "substate": bounded_text(metric.get("substate"), 64),
            "uptimeSeconds": None,
            "listeners": [],
        })
    result.sort(key=lambda item: (not bool(item.get("listeners")), item["name"].lower(), item["id"]))
    return result[:MAX_REMOTE_WORKLOADS]


def remote_workloads(expected_metrics):
    try:
        completed = subprocess.run(
            ["ss", "-H", "-ltnp"], capture_output=True, text=True, timeout=3, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return merge_expected_workloads([], expected_metrics)
    observed = parse_listening_workloads(completed.stdout) if completed.returncode == 0 else []
    return merge_expected_workloads(observed, expected_metrics)


def valid_resource_unit(value):
    unit = bounded_text(value, 128)
    if not unit or not re.fullmatch(r"[A-Za-z0-9_.@:-]{1,128}\.(?:service|scope)", unit):
        return None
    return unit


def resource_scope_is_relevant(process_name, unit):
    if not unit or not unit.endswith(".scope"):
        return True
    identity = " ".join(filter(None, [process_name, unit])).lower()
    return any(name in identity for name in RESOURCE_SCOPE_PROCESSES)


def top_process_resource_candidates(table):
    result = []
    seen = set()
    for value_key in ("cpuPercent", "residentBytes"):
        accepted = 0
        for item in sorted(table, key=lambda entry: entry[value_key], reverse=True)[:64]:
            process_name = bounded_text(item["name"], 128)
            if not process_name:
                continue
            cgroup_path, raw_unit = process_cgroup_identity(item["pid"])
            unit = valid_resource_unit(raw_unit)
            if not cgroup_path or not unit or not resource_scope_is_relevant(process_name, unit):
                continue
            if cgroup_path in seen:
                continue
            seen.add(cgroup_path)
            result.append({
                "name": unit if unit.endswith(".service") else process_name,
                "systemdUnit": unit,
                "cgroupPath": cgroup_path,
            })
            accepted += 1
            if accepted >= MAX_RESOURCE_CANDIDATES_PER_SORT:
                break
    return result


def systemd_control_groups(units):
    names = []
    seen = set()
    for value in units:
        unit = valid_resource_unit(value)
        if unit and unit not in seen:
            seen.add(unit)
            names.append(unit)
        if len(names) >= MAX_RESOURCE_CONTROLS:
            break
    if not names:
        return {}
    command = [
        "systemctl", "show", "--no-pager", "--property=Id,ControlGroup",
    ] + names
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=3, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0 and not completed.stdout.strip():
        return {}
    result = {}
    for block in completed.stdout.strip().split("\n\n"):
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        unit = valid_resource_unit(values.get("Id"))
        path = bounded_text(values.get("ControlGroup"), 256)
        if unit and path and path.startswith("/"):
            result[unit] = path
    return result


def resource_control_candidates(workloads, io_processes, process_candidates):
    service_candidates = []
    observed_candidates = []
    service_units = []
    for workload in workloads or []:
        unit = valid_resource_unit(workload.get("systemdUnit"))
        if unit and unit.endswith(".service"):
            service_units.append(unit)
            service_candidates.append({"name": workload.get("name") or unit, "systemdUnit": unit})
    for process in io_processes or []:
        unit = valid_resource_unit(process.get("systemdUnit"))
        name = bounded_text(process.get("name"), 128)
        if not unit or not resource_scope_is_relevant(name, unit):
            continue
        service_units.append(unit)
        observed_candidates.append({
            "name": unit if unit.endswith(".service") else name,
            "systemdUnit": unit,
        })
    for candidate in process_candidates:
        unit = valid_resource_unit(candidate.get("systemdUnit"))
        name = bounded_text(candidate.get("name"), 128)
        if not unit or not resource_scope_is_relevant(name, unit):
            continue
        observed_candidates.append({
            "name": name or unit,
            "systemdUnit": unit,
            "cgroupPath": bounded_text(candidate.get("cgroupPath"), 256),
        })

    control_groups = systemd_control_groups(service_units)
    # Keep explicitly watched/listening services primary while reserving room
    # for the active agent/browser contributors that explain host contention.
    candidates = (
        service_candidates[:12]
        + observed_candidates[:4]
        + service_candidates[12:]
        + observed_candidates[4:]
    )
    result = []
    seen = set()
    for candidate in candidates:
        unit = valid_resource_unit(candidate.get("systemdUnit"))
        cgroup_path = bounded_text(
            candidate.get("cgroupPath") or control_groups.get(unit), 256
        )
        identity = cgroup_path or unit
        if not identity or identity in seen:
            continue
        seen.add(identity)
        result.append({
            "name": bounded_text(candidate.get("name"), 128) or unit or "Workload",
            "systemdUnit": unit,
            "cgroupPath": cgroup_path,
        })
        if len(result) >= MAX_RESOURCE_CONTROLS:
            break
    return result


def read_cgroup_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            value = handle.read(MAX_CGROUP_FILE_BYTES + 1)
    except FileNotFoundError:
        return "unsupported", None
    except OSError:
        return "unavailable", None
    if len(value) > MAX_CGROUP_FILE_BYTES:
        return "unavailable", None
    return "available", value.strip()


def unavailable_value(state):
    return {"availability": state, "value": None}


def unavailable_limit(state):
    return {"state": state, "value": None}


def unavailable_quota(state):
    return {
        "state": state,
        "quotaMicroseconds": None,
        "periodMicroseconds": None,
    }


def unavailable_pressure(state):
    return {"availability": state, "someAverage10": None, "fullAverage10": None}


def integer_value(path, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return unavailable_value(state)
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return unavailable_value("unavailable")
    if value < 0:
        return unavailable_value("unavailable")
    return {"availability": "available", "value": value}


def limit_value(path, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return unavailable_limit(state)
    if raw == "max":
        return {"state": "unlimited", "value": None}
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return unavailable_limit("unavailable")
    if value < 0:
        return unavailable_limit("unavailable")
    return {"state": "configured", "value": value}


def keyed_integer_values(path, keys, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return {key: unavailable_value(state) for key in keys}
    values = {}
    for line in str(raw or "").splitlines()[:64]:
        fields = line.split()
        if len(fields) != 2 or fields[0] not in keys:
            continue
        try:
            value = int(fields[1])
        except ValueError:
            continue
        if value >= 0:
            values[fields[0]] = {"availability": "available", "value": value}
    return {key: values.get(key, unavailable_value("unavailable")) for key in keys}


def cpu_quota(path, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return unavailable_quota(state)
    fields = str(raw or "").split()
    if len(fields) != 2:
        return unavailable_quota("unavailable")
    try:
        period = int(fields[1])
        quota = None if fields[0] == "max" else int(fields[0])
    except ValueError:
        return unavailable_quota("unavailable")
    if period <= 0 or (quota is not None and quota < 0):
        return unavailable_quota("unavailable")
    return {
        "state": "unlimited" if quota is None else "configured",
        "quotaMicroseconds": quota,
        "periodMicroseconds": period,
    }


def io_weight(path, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return unavailable_value(state)
    for line in str(raw or "").splitlines()[:64]:
        fields = line.split()
        if len(fields) == 2 and fields[0] == "default":
            try:
                value = int(fields[1])
            except ValueError:
                break
            if value > 0:
                return {"availability": "available", "value": value}
    return unavailable_value("unavailable")


def cgroup_pressure(path, reader=read_cgroup_file):
    state, raw = reader(path)
    if state != "available":
        return unavailable_pressure(state)
    values = {}
    for line in str(raw or "").splitlines()[:8]:
        fields = line.split()
        if not fields or fields[0] not in {"some", "full"}:
            continue
        parsed = dict(field.split("=", 1) for field in fields[1:] if "=" in field)
        try:
            average = float(parsed["avg10"])
        except (KeyError, ValueError):
            continue
        if math.isfinite(average) and average >= 0:
            values[fields[0]] = average
    if "some" not in values or "full" not in values:
        return unavailable_pressure("unavailable")
    return {
        "availability": "available",
        "someAverage10": values["some"],
        "fullAverage10": values["full"],
    }


def safe_cgroup_directory(root, cgroup_path):
    path = str(cgroup_path or "")
    if not path.startswith("/") or len(path) > 256 or "\x00" in path:
        return None
    components = path.split("/")[1:]
    if not components or any(component in {"", ".", ".."} for component in components):
        return None
    root_path = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root_path, *components))
    try:
        if os.path.commonpath([root_path, candidate]) != root_path:
            return None
    except ValueError:
        return None
    return candidate


def empty_resource_control(candidate, state):
    value = unavailable_value(state)
    limit = unavailable_limit(state)
    quota = unavailable_quota(state)
    pressure_value = unavailable_pressure(state)
    return {
        "id": bounded_text(candidate.get("cgroupPath") or candidate.get("systemdUnit"), 256)
            or "unavailable-workload",
        "name": bounded_text(candidate.get("name"), 128) or "Workload",
        "systemdUnit": valid_resource_unit(candidate.get("systemdUnit")),
        "cgroupPath": bounded_text(candidate.get("cgroupPath"), 256),
        "availability": state,
        "memoryCurrentBytes": value,
        "memoryPeakBytes": value,
        "memoryHigh": limit,
        "memoryMax": limit,
        "memoryEvents": {"high": value, "max": value, "oom": value, "oomKill": value},
        "cpuQuota": quota,
        "cpuWeight": value,
        "cpuStat": {
            "usageMicroseconds": value,
            "userMicroseconds": value,
            "systemMicroseconds": value,
            "periods": value,
            "throttledPeriods": value,
            "throttledMicroseconds": value,
        },
        "ioWeight": value,
        "ioPressure": pressure_value,
        "tasksCurrent": value,
        "tasksMax": limit,
    }


def collect_resource_control(candidate, root="/sys/fs/cgroup", reader=read_cgroup_file):
    root_state, _ = reader(os.path.join(root, "cgroup.controllers"))
    if root_state != "available":
        return empty_resource_control(
            candidate, "unsupported" if root_state == "unsupported" else "unavailable"
        )
    directory = safe_cgroup_directory(root, candidate.get("cgroupPath"))
    if not directory or not os.path.isdir(directory):
        return empty_resource_control(candidate, "unavailable")

    memory_events = keyed_integer_values(
        os.path.join(directory, "memory.events"), ["high", "max", "oom", "oom_kill"], reader
    )
    cpu_stat = keyed_integer_values(
        os.path.join(directory, "cpu.stat"),
        ["usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"],
        reader,
    )
    result = empty_resource_control(candidate, "unavailable")
    result.update({
        "availability": "available",
        "memoryCurrentBytes": integer_value(os.path.join(directory, "memory.current"), reader),
        "memoryPeakBytes": integer_value(os.path.join(directory, "memory.peak"), reader),
        "memoryHigh": limit_value(os.path.join(directory, "memory.high"), reader),
        "memoryMax": limit_value(os.path.join(directory, "memory.max"), reader),
        "memoryEvents": {
            "high": memory_events["high"],
            "max": memory_events["max"],
            "oom": memory_events["oom"],
            "oomKill": memory_events["oom_kill"],
        },
        "cpuQuota": cpu_quota(os.path.join(directory, "cpu.max"), reader),
        "cpuWeight": integer_value(os.path.join(directory, "cpu.weight"), reader),
        "cpuStat": {
            "usageMicroseconds": cpu_stat["usage_usec"],
            "userMicroseconds": cpu_stat["user_usec"],
            "systemMicroseconds": cpu_stat["system_usec"],
            "periods": cpu_stat["nr_periods"],
            "throttledPeriods": cpu_stat["nr_throttled"],
            "throttledMicroseconds": cpu_stat["throttled_usec"],
        },
        "ioWeight": io_weight(os.path.join(directory, "io.weight"), reader),
        "ioPressure": cgroup_pressure(os.path.join(directory, "io.pressure"), reader),
        "tasksCurrent": integer_value(os.path.join(directory, "pids.current"), reader),
        "tasksMax": limit_value(os.path.join(directory, "pids.max"), reader),
    })
    return result


def workload_resource_controls(workloads, io_processes, table):
    candidates = resource_control_candidates(
        workloads, io_processes, top_process_resource_candidates(table)
    )
    return [collect_resource_control(candidate) for candidate in candidates[:MAX_RESOURCE_CONTROLS]]


def journal_timestamp(entry):
    raw = entry.get("_SOURCE_REALTIME_TIMESTAMP") or entry.get("__REALTIME_TIMESTAMP")
    try:
        return int(raw) / 1_000_000
    except (TypeError, ValueError):
        return None


def kernel_size_bytes(match):
    if not match:
        return None
    value = int(match.group(1))
    unit = (match.group(2) or "B").lower()
    multiplier = {"kb": 1_024, "mb": 1_024 ** 2, "gb": 1_024 ** 3}.get(unit, 1)
    return value * multiplier


def parse_oom_entries(entries):
    normalized = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        timestamp = journal_timestamp(entry)
        message = bounded_text(entry.get("MESSAGE"), 512)
        if timestamp is not None and message:
            normalized.append((timestamp, message))
    normalized.sort(key=lambda item: item[0])

    events = []
    for index, (timestamp, message) in enumerate(normalized):
        if "Killed process" not in message:
            continue
        victim_match = re.search(r"Killed process\s+(\d+)\s+\(([^)]+)\)", message)
        context_messages = [
            candidate
            for candidate_timestamp, candidate in normalized[max(0, index - 12):index + 1]
            if 0 <= timestamp - candidate_timestamp <= 5
        ]
        context = " ".join(context_messages)
        constraint_match = re.search(r"constraint=([^,\s]+)", context)
        cgroup_match = re.search(r"task_memcg=([^,\s]+)", context)
        usage_match = re.search(r"memory:\s+usage\s+(\d+)\s*(kB|MB|GB|B)?", context, re.IGNORECASE)
        limit_match = re.search(r"limit\s+(\d+)\s*(kB|MB|GB|B)?", context, re.IGNORECASE)
        cgroup = bounded_text(cgroup_match.group(1), 160) if cgroup_match else None
        constraint_value = constraint_match.group(1) if constraint_match else ""
        if "MEMCG" in constraint_value or "Memory cgroup out of memory" in context or cgroup not in {None, "/"}:
            constraint = "cgroup"
        elif "Out of memory: Killed process" in context or constraint_value:
            constraint = "system"
        else:
            constraint = "unknown"
        events.append({
            "timestamp": timestamp,
            "victimProcess": bounded_text(victim_match.group(2), 64) if victim_match else None,
            "processID": int(victim_match.group(1)) if victim_match else None,
            "cgroup": cgroup,
            "constraint": constraint,
            "memoryUsageBytes": kernel_size_bytes(usage_match),
            "memoryLimitBytes": kernel_size_bytes(limit_match),
        })
    return events


def oom_events():
    command = [
        "journalctl", "-k", "-b", "0", "--no-pager", "-q", "-o", "json",
        "-n", str(MAX_OOM_JOURNAL_ROWS),
        "--grep", "Killed process|oom-kill:|memory: usage",
    ]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=3, check=False)
        if completed.returncode != 0:
            return 0, None, None, "unavailable"
        entries = []
        for line in completed.stdout.splitlines()[:MAX_OOM_JOURNAL_ROWS]:
            try:
                entry = json.loads(line)
                if isinstance(entry, dict):
                    entries.append(entry)
            except json.JSONDecodeError:
                continue
        events = parse_oom_entries(entries)
        latest = events[-1] if events else None
        return len(events), latest.get("timestamp") if latest else None, latest, "available"
    except (OSError, subprocess.TimeoutExpired):
        return 0, None, None, "unavailable"


def oom_kill_mark(boot_id, vmstat_path="/proc/vmstat"):
    for line in read_text(vmstat_path).splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == "oom_kill" and fields[1].isdigit():
            return f"{boot_id or 'unknown'}:{fields[1]}"
    return None


# The kernel's cumulative oom_kill counter cannot change without a new kill,
# so an unchanged mark lets the caller reuse its previous journal evidence
# instead of scanning the current boot's kernel journal on every sample.
def oom_context(mark, previous_mark):
    if mark is not None and mark == previous_mark:
        return {
            "oomKillCount": 0,
            "lastOOMKillAt": None,
            "oomCollectionStatus": None,
            "latestOOMEvent": None,
            "oomEvidenceUnchanged": True,
        }
    count, last_at, event, status = oom_events()
    return {
        "oomKillCount": count,
        "lastOOMKillAt": last_at,
        "oomCollectionStatus": status,
        "latestOOMEvent": event,
        "oomEvidenceUnchanged": False,
    }


def collect_linux():
    memory = meminfo()
    swap_total = memory.get("SwapTotal", 0)
    swap_free = memory.get("SwapFree", 0)
    filesystem = os.statvfs("/")
    disk_total = filesystem.f_blocks * filesystem.f_frsize
    disk_available = filesystem.f_bavail * filesystem.f_frsize
    disk_read, disk_write = disk_totals()
    network_receive, network_transmit = network_totals()
    loads = os.getloadavg()
    boot_id = read_text("/proc/sys/kernel/random/boot_id").strip() or None
    mark = oom_kill_mark(boot_id)
    oom = oom_context(mark, os.environ.get("MACHINEPULSE_OOM_KILL_MARK"))
    table = process_table()
    cpu_pressure = pressure("cpu")
    memory_pressure = pressure("memory")
    io_pressure = pressure("io")
    cpu, io_processes = activity_sample(
        cpu_ticks,
        max(io_pressure["someAverage10"], io_pressure["fullAverage10"]) >= IO_AUDIT_MINIMUM_AVERAGE_10,
    )

    expected_metrics = expected_units()
    workloads = remote_workloads(expected_metrics)
    snapshot = {
        "timestamp": time.time(),
        "hostname": socket.gethostname(),
        "uptimeSeconds": host_uptime(),
        "cpuPercent": cpu,
        "logicalCPUCount": os.cpu_count() or 1,
        "loadAverage1": loads[0],
        "loadAverage5": loads[1],
        "loadAverage15": loads[2],
        "memoryTotalBytes": memory.get("MemTotal", 0),
        "memoryAvailableBytes": memory.get("MemAvailable", memory.get("MemFree", 0)),
        "swapTotalBytes": swap_total,
        "swapUsedBytes": max(0, swap_total - swap_free),
        "diskTotalBytes": disk_total,
        "diskUsedBytes": max(0, disk_total - disk_available),
        "diskReadBytesTotal": disk_read,
        "diskWriteBytesTotal": disk_write,
        "networkReceiveBytesTotal": network_receive,
        "networkTransmitBytesTotal": network_transmit,
        "cpuPressure": cpu_pressure,
        "memoryPressure": memory_pressure,
        "ioPressure": io_pressure,
        "topCPUProcesses": top_processes(table, "cpuPercent"),
        "topMemoryProcesses": top_processes(table, "residentBytes"),
        "topIOProcesses": io_processes,
        "failedServices": failed_services(),
        "expectedUnits": expected_metrics,
        "remoteWorkloads": workloads,
        "workloadResourceControls": workload_resource_controls(workloads, io_processes, table),
        "oomKillMark": mark,
        "bootID": boot_id,
        "collectorVersion": LINUX_COLLECTOR_VERSION,
        "rootFilesystemID": root_filesystem_identity(),
    }
    snapshot.update(oom)
    return snapshot


def darwin_cpu_ticks():
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    ticks = (ctypes.c_uint32 * 4)()
    count = ctypes.c_uint32(4)
    status = libc.host_statistics(
        libc.mach_host_self(), DARWIN_HOST_CPU_LOAD_INFO, ctypes.byref(ticks), ctypes.byref(count)
    )
    if status != 0:
        return 0, 0
    user, system, idle, nice = ticks
    return user + system + idle + nice, idle


def darwin_sysctl():
    try:
        output = subprocess.run(
            ["sysctl"] + DARWIN_SYSCTL_KEYS, capture_output=True, text=True, timeout=2, check=False
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    values = {}
    for line in output.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            values[key.strip()] = value.strip()
    return values


def darwin_size_bytes(text):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGT]?)", str(text or "").strip())
    if not match:
        return 0
    multiplier = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}[match.group(2)]
    return int(float(match.group(1)) * multiplier)


def darwin_swap(text):
    values = dict(re.findall(r"(total|used) = ([0-9.]+[KMGT]?)", str(text or "")))
    return darwin_size_bytes(values.get("total")), darwin_size_bytes(values.get("used"))


def darwin_boot_time(text):
    match = re.search(r"sec = (\d+)", str(text or ""))
    return int(match.group(1)) if match else None


def darwin_memory_pressure_level(text):
    level = number(text, 0)
    if level >= 4:
        return "critical"
    if level >= 2:
        return "warning"
    return "normal" if level >= 1 else None


def darwin_vm_stat():
    try:
        output = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=2, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}, 0
    page_match = re.search(r"page size of (\d+)", output)
    page_size = int(page_match.group(1)) if page_match else 0
    values = {}
    for line in output.splitlines()[1:]:
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        digits = raw.strip().rstrip(".")
        if digits.isdigit():
            values[key.strip().strip('"')] = int(digits)
    return values, page_size


def darwin_memory(total):
    values, page_size = darwin_vm_stat()
    available = (values.get("Pages free", 0) + values.get("File-backed pages", 0)) * page_size
    return {
        "available": min(total, available) if total else available,
        "swapInBytesTotal": values.get("Swapins", 0) * page_size,
        "swapOutBytesTotal": values.get("Swapouts", 0) * page_size,
    }


def darwin_network_totals():
    try:
        output = subprocess.run(
            ["netstat", "-ibn"], capture_output=True, text=True, timeout=2, check=False
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0, 0
    received = 0
    transmitted = 0
    seen = set()
    for line in output.splitlines()[1:]:
        fields = line.split()
        # Only the link-level row carries the interface totals; the address
        # column is absent for some interfaces, so counters are read from the
        # right-hand end of the row.
        if len(fields) < 10 or not fields[2].startswith("<Link#"):
            continue
        interface = fields[0]
        if interface in seen or interface.startswith("lo"):
            continue
        seen.add(interface)
        try:
            received += int(fields[-5])
            transmitted += int(fields[-2])
        except ValueError:
            continue
    return received, transmitted


def darwin_disk_io_totals():
    try:
        output = subprocess.run(
            ["ioreg", "-r", "-c", "IOBlockStorageDriver", "-w", "0", "-a"],
            capture_output=True, timeout=3, check=False,
        ).stdout
        entries = plistlib.loads(output) if output.strip() else []
    except (OSError, subprocess.TimeoutExpired, ValueError, plistlib.InvalidFileException,
            xml.parsers.expat.ExpatError):
        return 0, 0
    read = 0
    write = 0
    stack = list(entries) if isinstance(entries, list) else []
    while stack:
        entry = stack.pop()
        if not isinstance(entry, dict):
            continue
        statistics = entry.get("Statistics")
        if isinstance(statistics, dict):
            read += int(number(statistics.get("Bytes (Read)"), 0))
            write += int(number(statistics.get("Bytes (Write)"), 0))
        stack.extend(entry.get("IORegistryEntryChildren") or [])
    return read, write


def darwin_disk():
    filesystem = os.statvfs("/")
    total = filesystem.f_blocks * filesystem.f_frsize
    available = filesystem.f_bavail * filesystem.f_frsize
    return total, max(0, total - available)


def collect_darwin():
    values = darwin_sysctl()
    total_memory = int(number(values.get("hw.memsize"), 0))
    memory = darwin_memory(total_memory)
    swap_total, swap_used = darwin_swap(values.get("vm.swapusage"))
    disk_total, disk_used = darwin_disk()
    disk_read, disk_write = darwin_disk_io_totals()
    network_receive, network_transmit = darwin_network_totals()
    boot_time = darwin_boot_time(values.get("kern.boottime"))
    loads = os.getloadavg()
    cpu, _ = activity_sample(darwin_cpu_ticks, False)
    table = process_table()
    for item in table:
        item["name"] = item["name"].rsplit("/", 1)[-1] or item["name"]
    now = time.time()
    return {
        "timestamp": now,
        "hostname": socket.gethostname(),
        "uptimeSeconds": max(0.0, now - boot_time) if boot_time else 0.0,
        "cpuPercent": cpu,
        "logicalCPUCount": int(number(values.get("hw.ncpu"), 0)) or os.cpu_count() or 1,
        "loadAverage1": loads[0],
        "loadAverage5": loads[1],
        "loadAverage15": loads[2],
        "memoryTotalBytes": total_memory,
        "memoryAvailableBytes": memory["available"],
        "swapTotalBytes": swap_total,
        "swapUsedBytes": swap_used,
        "diskTotalBytes": disk_total,
        "diskUsedBytes": disk_used,
        "diskReadBytesTotal": disk_read,
        "diskWriteBytesTotal": disk_write,
        "networkReceiveBytesTotal": network_receive,
        "networkTransmitBytesTotal": network_transmit,
        "swapInBytesTotal": memory["swapInBytesTotal"],
        "swapOutBytesTotal": memory["swapOutBytesTotal"],
        "memoryPressureLevel": darwin_memory_pressure_level(
            values.get("kern.memorystatus_vm_pressure_level")
        ),
        "topCPUProcesses": top_processes(table, "cpuPercent"),
        "topMemoryProcesses": top_processes(table, "residentBytes"),
        "failedServices": [],
        "oomKillCount": 0,
        "bootID": values.get("kern.bootsessionuuid") or None,
        "collectorVersion": DARWIN_COLLECTOR_VERSION,
        "rootFilesystemID": root_device_identity(),
    }


# --- Disk composition ---------------------------------------------------------
# A bounded walk of a directory tree, ported from disktree (MIT, Tobi Lütke):
# sizes are st_blocks * 512, hardlinks count once, symlinks are not followed,
# the walk stays on one filesystem and never opens a cloud-only folder. Kinds
# and reclaimable reasons come from names; findings are judged when a
# directory closes. Only the largest entries within the depth bound are kept.

DISK_SCANNER_VERSION = (
    "mac-agentless-disk-v1" if sys.platform == "darwin" else "linux-agentless-disk-v1"
)
DISK_RETAIN_FLOOR = 4 * 1024 * 1024
DISK_FINDING_FLOOR = 64 * 1024 * 1024
DISK_MAX_CHILDREN = 96
DISK_MAX_DEPTH = 4
DISK_MAX_FINDINGS = 12
DISK_STALE_DAYS = 30
DISK_DATALESS_FLAG = 0x40000000

DISK_KIND_NAMES = {}
for _kind, _names in (
    ("code", ("src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces",
              "github.com", "gitlab.com", "sites", "development")),
    ("agentScratch", (".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini",
                      ".continue", ".windsurf", ".microsandbox", ".omp", ".agents", ".openai",
                      "tries", "worktrees", "experiments", "scratch", "playground")),
    ("toolchain", (".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno",
                   "go", ".gradle", ".m2", ".platformio", "mise", ".mise", ".pyenv", ".nvm",
                   ".gem", "gem", ".rbenv", ".espressif", ".arduino15", ".config", ".vscode",
                   ".zig", ".rye", ".conda", "anaconda3", "miniconda3", ".opam", ".ghcup",
                   ".stack", ".julia", ".dotnet", ".android", ".sdkman", ".volta", ".yarn",
                   ".java", ".nuget", "xcode", "coresimulator")),
    ("synced", ("sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega",
                ".stversions", "mobile documents", "cloudstorage", "iclouddrive")),
    ("git", (".git",)),
    ("media", ("pictures", "photos", "music", "videos", "movies", "steam", "steamlibrary",
               "steamapps", "emulation", "models", ".ollama", ".lmstudio", "games", "wineprefix")),
    ("documents", ("documents", "desktop", "downloads", "books", "notes", "obsidian", "public",
                   "templates")),
    ("cache", (".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__",
               "node_modules", "trash", ".trash", "tmp", ".tmp", "deriveddata",
               "ios devicesupport", "watchos devicesupport", "temp", "$recycle.bin", "npm-cache",
               "v3-cache", "inetcache", "d3dscache", "dxcache", "glcache", "crashdumps")),
):
    for _name in _names:
        DISK_KIND_NAMES[_name] = _kind

DISK_RECLAIM_NAMES = {}
for _reason, _names in (
    ("regenerable", (".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "npm-cache",
                     "v3-cache", "inetcache", "d3dscache", "dxcache", "glcache",
                     "ios devicesupport", "watchos devicesupport")),
    ("syncHistory", (".stversions",)),
    ("packageStore", (".pnpm-store", "pnpm")),
    ("buildOutput", ("__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo",
                     ".parcel-cache", "deriveddata")),
    ("trash", ("trash", ".trash", "$recycle.bin")),
    ("temporary", ("tmp", ".tmp", "temp", "crashdumps")),
):
    for _name in _names:
        DISK_RECLAIM_NAMES[_name] = _reason


def disk_kind_of_name(name):
    lower = name.lower()
    if lower.startswith("onedrive - ") or lower.startswith("dropbox ("):
        return "synced"
    return DISK_KIND_NAMES.get(lower)


class DiskFlags:
    __slots__ = ("cargo", "package", "application_support", "objects", "refs", "head")

    def __init__(self, names=()):
        self.cargo = self.package = self.application_support = False
        self.objects = self.refs = self.head = False
        for name in names:
            self.note(name)

    def note(self, name):
        if name == "Cargo.toml":
            self.cargo = True
        elif name == "package.json":
            self.package = True
        elif name == "Application Support":
            self.application_support = True
        elif name == "objects":
            self.objects = True
        elif name == "refs":
            self.refs = True
        elif name == "HEAD":
            self.head = True

    @property
    def is_git_store(self):
        return self.objects and self.refs and self.head


def disk_reclaim_of(name, parent_kind, siblings):
    lower = name.lower()
    reason = DISK_RECLAIM_NAMES.get(lower)
    if reason:
        return reason
    if lower == "logs" and siblings.application_support:
        return "temporary"
    if lower == "target" and siblings.cargo:
        return "buildOutput"
    if lower == "node_modules" and siblings.package:
        return "reinstallable"
    if lower == "layers" and parent_kind == "agentScratch":
        return "sandboxLayers"
    if lower == "snapshots" and parent_kind == "agentScratch":
        return "snapshots"
    return None


def disk_node(name, entry_kind, size, files, directories, modified, read_error, kind, reclaim, children):
    return {
        "name": name,
        "entryKind": entry_kind,
        "bytes": size,
        "files": files,
        "directories": directories,
        "modifiedAt": modified if modified > 0 else None,
        "readError": read_error,
        "kind": kind,
        "reclaim": reclaim,
        "children": children,
        "remainderBytes": 0,
        "remainderCount": 0,
    }


def disk_dominant_child_kind(node):
    for _ in range(3):
        for child in node["children"]:
            if child["entryKind"] != "directory":
                continue
            kind = disk_kind_of_name(child["name"]) or ("git" if child["kind"] == "git" else None)
            if kind:
                return kind
        node = next((child for child in node["children"] if child["entryKind"] == "directory"), None)
        if node is None:
            return None
    return None


def disk_recolor(node, old, new):
    if node["kind"] != old:
        return
    node["kind"] = new
    for child in node["children"]:
        disk_recolor(child, old, new)


def disk_prune(node, floor):
    node["children"] = [child for child in node["children"] if child["bytes"] >= floor]
    shown_bytes = 0
    shown_entries = 0
    for child in node["children"]:
        disk_prune(child, floor)
        shown_bytes += child["bytes"]
        shown_entries += child["files"] + child["directories"] + (1 if child["entryKind"] == "directory" else 0)
    node["remainderBytes"] = max(0, node["bytes"] - shown_bytes)
    node["remainderCount"] = max(0, node["files"] + node["directories"] - shown_entries)


class DiskFrame:
    __slots__ = (
        "level", "name", "path", "kind", "reclaim", "recognised", "flags", "bytes", "files",
        "directories", "modified", "read_error", "retained", "child_dirs", "findings_start",
        "judges_children",
    )

    def __init__(self, level, name, path, kind, reclaim, recognised, flags, findings_start, judges_children):
        self.level = level
        self.name = name
        self.path = path
        self.kind = kind
        self.reclaim = reclaim
        self.recognised = recognised
        self.flags = flags
        self.bytes = 0
        self.files = 0
        self.directories = 0
        self.modified = 0
        self.read_error = False
        self.retained = []
        self.child_dirs = []
        self.findings_start = findings_start
        self.judges_children = judges_children


class DiskEngine:
    def __init__(self, root_name, root_flags, options):
        self.options = options
        self.now = int(options.get("now", time.time()))
        self.stale_seconds = options.get("staleDays", DISK_STALE_DAYS) * 86400
        self.retain_floor = options.get("retainFloorBytes", DISK_RETAIN_FLOOR)
        self.finding_floor = options.get("findingFloorBytes", DISK_FINDING_FLOOR)
        self.max_children = options.get("maxChildren", DISK_MAX_CHILDREN)
        self.max_depth = options.get("maxDepth", DISK_MAX_DEPTH)
        self.max_findings = options.get("maxFindings", DISK_MAX_FINDINGS)
        self.findings = []
        self.unreadable = 0
        self.frames = [DiskFrame(0, root_name, "", "other", None, True, root_flags, 0, False)]

    def enter_directory(self, name, flags):
        parent = self.frames[-1]
        kind = disk_kind_of_name(name) or ("git" if flags.is_git_store else parent.kind)
        recognised = disk_kind_of_name(name) is not None or flags.is_git_store
        reclaim = parent.reclaim or disk_reclaim_of(name, parent.kind, parent.flags)
        lower = name.lower()
        judges = kind == "agentScratch" and reclaim is None and lower in ("worktrees", "tries", "experiments")
        self.frames.append(DiskFrame(
            parent.level + 1, name, name if not parent.path else parent.path + "/" + name,
            kind, reclaim, recognised, flags, len(self.findings), judges,
        ))

    def mark_unreadable(self):
        self.frames[-1].read_error = True
        self.unreadable += 1

    def add_entry(self, name, entry_kind, size, modified):
        frame = self.frames[-1]
        frame.bytes += size
        if entry_kind != "other":
            frame.files += 1
        if modified > frame.modified:
            frame.modified = modified
        if frame.level >= self.max_depth or size < self.retain_floor:
            return
        frame.retained.append(disk_node(
            name, entry_kind, size, 0 if entry_kind == "other" else 1, 0, modified, False,
            frame.kind, frame.reclaim, [],
        ))

    def add_skipped_directory(self, size, modified):
        frame = self.frames[-1]
        frame.bytes += size
        frame.directories += 1
        if modified > frame.modified:
            frame.modified = modified

    def leave_directory(self, own_bytes, own_modified):
        frame = self.frames.pop()
        frame.bytes += own_bytes
        if own_modified > frame.modified:
            frame.modified = own_modified
        frame.retained.sort(key=lambda node: (-node["bytes"], node["name"]))
        del frame.retained[self.max_children:]
        if frame.level == 1 and not frame.recognised and frame.kind == "other":
            dominant = disk_dominant_child_kind({"children": frame.retained})
            if dominant:
                frame.kind = dominant
                for node in frame.retained:
                    disk_recolor(node, "other", dominant)
        self.judge(frame)
        node = disk_node(
            frame.name, "directory", frame.bytes, frame.files, frame.directories, frame.modified,
            frame.read_error, frame.kind, frame.reclaim, frame.retained,
        )
        parent = self.frames[-1]
        parent.bytes += frame.bytes
        parent.files += frame.files
        parent.directories += frame.directories + 1
        if frame.modified > parent.modified:
            parent.modified = frame.modified
        if parent.judges_children:
            parent.child_dirs.append((frame.name, frame.bytes, frame.modified))
        if frame.level <= self.max_depth and frame.bytes >= self.retain_floor:
            parent.retained.append(node)

    def judge(self, frame):
        if frame.bytes < self.finding_floor:
            return
        if frame.reclaim:
            if self.frames[-1].reclaim is None:
                self.findings.append({
                    "path": frame.path, "bytes": frame.bytes, "kind": "reclaimable",
                    "reclaim": frame.reclaim, "count": None, "oldestDays": None,
                })
            return
        if not frame.judges_children:
            return
        if frame.name.lower() == "worktrees":
            if not frame.child_dirs:
                return
            stamps = [modified for _, _, modified in frame.child_dirs if modified > 0]
            oldest = min(stamps) if stamps else self.now
            del self.findings[frame.findings_start:]
            self.findings.append({
                "path": frame.path, "bytes": frame.bytes, "kind": "worktrees", "reclaim": None,
                "count": len(frame.child_dirs), "oldestDays": max(0, self.now - oldest) // 86400,
            })
            return
        stale = [item for item in frame.child_dirs if item[2] > 0 and self.now - item[2] > self.stale_seconds]
        if not stale:
            return
        prefixes = [frame.path + "/" + name + "/" for name, _, _ in stale]
        self.findings = [
            finding for finding in self.findings
            if not any(finding["path"].startswith(prefix) for prefix in prefixes)
        ]
        stale_bytes = sum(size for _, size, _ in stale)
        if stale_bytes < self.finding_floor:
            return
        self.findings.append({
            "path": frame.path, "bytes": stale_bytes, "kind": "staleExperiments", "reclaim": None,
            "count": len(stale), "oldestDays": None,
        })

    def finish(self, root_own_bytes, root_modified):
        frame = self.frames.pop()
        frame.bytes += root_own_bytes
        if root_modified > frame.modified:
            frame.modified = root_modified
        frame.retained.sort(key=lambda node: (-node["bytes"], node["name"]))
        del frame.retained[self.max_children:]
        root = disk_node(
            frame.name, "directory", frame.bytes, frame.files, frame.directories, frame.modified,
            frame.read_error, "other", None, frame.retained,
        )
        disk_prune(root, max(self.retain_floor, root["bytes"] // 2048))
        ranked = [finding for finding in self.findings if finding["bytes"] >= self.finding_floor]
        ranked.sort(key=lambda finding: (-finding["bytes"], finding["path"]))
        return root, ranked[:self.max_findings]


def disk_list(path):
    try:
        with os.scandir(path) as entries:
            return list(entries)
    except OSError:
        return None


def disk_volume(path):
    try:
        status = os.statvfs(path)
    except OSError:
        return None
    unit = status.f_frsize or status.f_bsize
    return {
        "totalBytes": status.f_blocks * unit,
        "freeBytes": status.f_bfree * unit,
        "availableBytes": status.f_bavail * unit,
    }


class DiskWalkFrame:
    __slots__ = ("entries", "index", "own_bytes", "own_modified")

    def __init__(self, entries, own_bytes=0, own_modified=0):
        self.entries = entries
        self.index = 0
        self.own_bytes = own_bytes
        self.own_modified = own_modified


def disk_scan(root=None, options=None):
    options = options or {}
    started = time.monotonic()
    root = os.path.abspath(root or os.environ.get("MACHINEPULSE_DISK_ROOT") or os.path.expanduser("~"))
    root_stat = os.lstat(root)
    root_entries = disk_list(root) or []
    engine = DiskEngine(
        os.path.basename(root) or root, DiskFlags(entry.name for entry in root_entries), options
    )
    retain_floor = engine.retain_floor
    seen_links = set()
    stack = [DiskWalkFrame(root_entries)]
    while stack:
        frame = stack[-1]
        if frame.index >= len(frame.entries):
            stack.pop()
            if stack:
                engine.leave_directory(frame.own_bytes, frame.own_modified)
            continue
        entry = frame.entries[frame.index]
        frame.index += 1
        try:
            status = entry.stat(follow_symlinks=False)
        except OSError:
            engine.mark_unreadable()
            continue
        size = status.st_blocks * 512
        modified = int(status.st_mtime)
        if entry.is_dir(follow_symlinks=False):
            if status.st_dev != root_stat.st_dev or getattr(status, "st_flags", 0) & DISK_DATALESS_FLAG:
                engine.add_skipped_directory(size, modified)
                continue
            children = disk_list(entry.path)
            engine.enter_directory(entry.name, DiskFlags(child.name for child in children or ()))
            if children is None:
                engine.mark_unreadable()
                engine.leave_directory(size, modified)
                continue
            stack.append(DiskWalkFrame(children, size, modified))
            continue
        if status.st_nlink > 1:
            key = (status.st_dev, status.st_ino)
            if key in seen_links:
                size = 0
            else:
                seen_links.add(key)
        if entry.is_symlink():
            entry_kind = "symlink"
        elif entry.is_file(follow_symlinks=False):
            entry_kind = "file"
        else:
            entry_kind = "other"
        engine.add_entry(entry.name if size >= retain_floor else "", entry_kind, size, modified)

    tree, findings = engine.finish(root_stat.st_blocks * 512, int(root_stat.st_mtime))
    return {
        "rootPath": root,
        "durationSeconds": time.monotonic() - started,
        "unreadableCount": engine.unreadable,
        "volume": disk_volume(root),
        "root": tree,
        "findings": findings,
        "scannerVersion": DISK_SCANNER_VERSION,
    }


def main():
    if os.environ.get("MACHINEPULSE_MODE") == "disk-scan":
        os.nice(19)
        print(json.dumps(disk_scan(), separators=(",", ":")))
        return
    if sys.platform.startswith("linux"):
        snapshot = collect_linux()
    elif sys.platform == "darwin":
        snapshot = collect_darwin()
    else:
        print(f"MachinePulse cannot collect metrics on {sys.platform}.", file=sys.stderr)
        sys.exit(3)
    print(json.dumps(snapshot, separators=(",", ":")))


if __name__ == "__main__":
    main()
PY
