import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import subprocess
import time


def parse_processes(text, package, uid):
    processes = []
    for line in text.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        process_id, owner, name = int(fields[0]), int(fields[1]), fields[2]
        if owner == uid or (owner // 100000 == uid // 100000
                            and (name == package or name.startswith(package + ':'))):
            processes.append(dict(pid=process_id, uid=owner, name=name))
    return sorted(processes, key=lambda process: process['pid'])


def parse_stat(text, expected_pid):
    match = re.fullmatch(r'(\d+) \((.*)\) (.*)', text.strip())
    if not match or int(match[1]) != expected_pid:
        raise ValueError('Invalid process stat.')
    fields = match[3].split()
    if len(fields) < 22:
        raise ValueError('Incomplete process stat.')
    return dict(cpu_ticks=int(fields[11]) + int(fields[12]),
                threads=int(fields[17]), start_ticks=int(fields[19]))


def parse_pss(text):
    match = re.search(r'TOTAL PSS:\s*(\d+)', text)
    if not match:
        match = re.search(r'^\s*TOTAL\s+(\d+)\s+', text, re.MULTILINE)
    return int(match[1]) if match else None


def parse_write_bytes(text):
    match = re.search(r'^write_bytes:\s*(\d+)\s*$', text, re.MULTILINE)
    return int(match[1]) if match else None


def parse_page_closed(text, package):
    activities = [line for line in text.splitlines()
                  if re.search(r'(?:topResumedActivity|mResumedActivity|ResumedActivity)\s*[:=]', line)]
    if not activities:
        return None
    return not any(re.search(r'\b' + re.escape(package) + r'/', line) for line in activities)


def parse_receiver_foreground(text):
    blocks = re.split(r'(?=ServiceRecord\{)', text)
    return any('com.pravera.flutter_foreground_task.service.ForegroundService' in block
               and re.search(r'\bisForeground=true\b', block) for block in blocks)


def counters_complete(sample):
    records = sample.get('processes', [])
    keys = ('pid', 'cpu_ticks', 'start_ticks', 'threads', 'pss_kib')
    return (bool(sample.get('complete')) and bool(records)
            and all(type(record.get(key)) is int and record[key] >= 0
                    for record in records for key in keys)
            and len({record['pid'] for record in records}) == len(records))


def summarize(samples, ticks_per_second, scenario, device_kind):
    if not isinstance(ticks_per_second, (int, float)) or not math.isfinite(ticks_per_second) or ticks_per_second <= 0:
        raise ValueError('Kernel ticks must be positive.')
    if any(not isinstance(sample.get('wall_seconds'), (int, float))
           or not math.isfinite(sample['wall_seconds']) for sample in samples):
        raise ValueError('Sample wall time must be finite.')
    intervals = []
    for before, after in zip(samples, samples[1:]):
        duration = after['wall_seconds'] - before['wall_seconds']
        previous = {record['pid']: record for record in before['processes']}
        current = {record['pid']: record for record in after['processes']}
        reason = None
        if duration <= 0:
            reason = 'nonpositive_wall_interval'
        elif not counters_complete(before) or not counters_complete(after):
            reason = 'missing_process_or_counter'
        elif not before.get('boot_id') or before['boot_id'] != after.get('boot_id'):
            reason = 'device_reboot_or_unknown_boot_id'
        elif not previous or previous.keys() != current.keys():
            reason = 'process_set_changed_or_empty'
        elif any(previous[process_id]['start_ticks'] != current[process_id]['start_ticks']
                 for process_id in previous):
            reason = 'process_restarted_or_pid_reused'
        elif any(current[process_id]['cpu_ticks'] < previous[process_id]['cpu_ticks']
                 for process_id in previous):
            reason = 'cpu_counter_regressed'
        delta = None if reason else sum(current[process_id]['cpu_ticks'] - previous[process_id]['cpu_ticks']
                                       for process_id in previous)
        intervals.append(dict(wall_seconds=duration, cpu_ticks=delta, excluded_reason=reason))
    measured_wall = sum(interval['wall_seconds'] for interval in intervals if interval['cpu_ticks'] is not None)
    measured_ticks = sum(interval['cpu_ticks'] for interval in intervals if interval['cpu_ticks'] is not None)
    elapsed = samples[-1]['wall_seconds'] - samples[0]['wall_seconds'] if len(samples) > 1 else 0
    complete = bool(intervals) and all(interval['excluded_reason'] is None for interval in intervals)
    pss_values = [sum(record['pss_kib'] for record in sample['processes'])
                  for sample in samples if counters_complete(sample)]
    cpu_percent = measured_ticks / ticks_per_second / measured_wall * 100 if measured_wall else None
    reasons = []
    if device_kind != 'physical':
        reasons.append('not_a_physical_device')
    if scenario != 'idle-receiving':
        reasons.append('diagnostic_not_idle_receiving')
    if elapsed < 1800:
        reasons.append('less_than_30_minutes')
    if not complete:
        reasons.append('incomplete_cpu_or_process_coverage')
    if not samples or any(not sample.get('service_foreground') or not sample.get('page_closed') for sample in samples):
        reasons.append('foreground_receiver_or_closed_page_not_verified')
    maximum_capture_span = max((sample.get('capture_span_seconds', 0) for sample in samples), default=0)
    if intervals and maximum_capture_span > min(interval['wall_seconds'] for interval in intervals) * 0.1:
        reasons.append('capture_span_exceeds_10_percent_of_interval')
    writes = None
    if complete and all(type(record.get('write_bytes')) is int and record['write_bytes'] >= 0
                        for sample in samples for record in sample['processes']):
        first = {record['pid']: record for record in samples[0]['processes']}
        last = {record['pid']: record for record in samples[-1]['processes']}
        differences = [last[process_id]['write_bytes'] - first[process_id]['write_bytes'] for process_id in first]
        if all(value >= 0 for value in differences) and all(
                {record['pid']: record['write_bytes'] for record in after['processes']}[record['pid']] >= record['write_bytes']
                for before, after in zip(samples, samples[1:])
                for record in before['processes']):
            writes = sum(differences)
    return dict(
        scenario=scenario, device_kind=device_kind, sample_count=len(samples),
        wall_seconds=elapsed, covered_wall_seconds=measured_wall,
        cumulative_cpu_seconds=measured_ticks / ticks_per_second if measured_wall else None,
        mean_cpu_percent_one_core=cpu_percent,
        peak_total_pss_mib=max(pss_values) / 1024 if pss_values else None,
        max_threads=max((sum(record['threads'] for record in sample['processes'])
                         for sample in samples if counters_complete(sample)), default=None),
        max_capture_span_seconds=maximum_capture_span,
        disk_write_bytes=writes, cpu_intervals=intervals,
        measurement_complete=complete, baseline_eligibility_issues=reasons,
        warning_budgets=dict(pss_mib=120, mean_cpu_percent_one_core=0.1),
        warnings=dict(pss_over_budget=max(pss_values) > 120 * 1024 if pss_values else None,
                      cpu_over_budget=cpu_percent > 0.1 if cpu_percent is not None else None),
        verdict='exploratory_measurement_not_final_acceptance',
        unverified=['single_connection', 'bidirectional_ip_traffic', '24_hour_stability',
                    'battery_and_wakeups', 'vendor_doze_behavior', 'notification_latency'],
    )


class Collector:
    def __init__(self, adb, serial, package, destination):
        self.adb = str(adb)
        self.serial = serial
        self.package = package
        self.destination = destination
        self.failures = []

    def capture(self, filename, arguments):
        try:
            result = subprocess.run([self.adb, '-s', self.serial, *arguments],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=30)
            code, output = result.returncode, result.stdout + result.stderr
        except (subprocess.TimeoutExpired, OSError) as error:
            code, output = -1, type(error).__name__
        header = dict(exit_code=code, utc=datetime.now(timezone.utc).isoformat(), arguments=arguments)
        (self.destination / filename).write_text(json.dumps(header) + '\n' + output, encoding='utf-8')
        if code:
            self.failures.append(dict(file=filename, exit_code=code))
        return code, output

    def context(self, prefix, processes=()):
        for name, command in [('battery', ['battery']), ('batterystats', ['batterystats', self.package]),
                              ('netstats', ['netstats', 'detail'])]:
            self.capture(f'{prefix}-{name}.txt', ['shell', 'dumpsys', *command])
        for process in processes:
            process_id = process['pid']
            self.capture(f'{prefix}-{process_id}-fds.txt', ['shell', 'ls', '-l', f'/proc/{process_id}/fd'])

    def sample(self, sequence, uid, started):
        prefix = f'{sequence:05d}'
        wall = time.monotonic() - started
        code, output = self.capture(prefix + '-processes.txt', ['shell', 'ps', '-A', '-n', '-o', 'PID,UID,NAME'])
        processes = parse_processes(output, self.package, uid) if not code else []
        complete = bool(processes) and code == 0
        records = []
        for process in processes:
            process_id = process['pid']
            stat_code, stat = self.capture(f'{prefix}-{process_id}-stat.txt', ['shell', 'cat', f'/proc/{process_id}/stat'])
            memory_code, memory = self.capture(f'{prefix}-{process_id}-meminfo.txt', ['shell', 'dumpsys', 'meminfo', '-d', str(process_id)])
            io_code, io = self.capture(f'{prefix}-{process_id}-io.txt', ['shell', 'cat', f'/proc/{process_id}/io'])
            record = dict(process, cpu_ticks=None, start_ticks=None, threads=None, pss_kib=None, write_bytes=None)
            try:
                if stat_code:
                    raise ValueError('Stat inaccessible.')
                record.update(parse_stat(stat, process_id))
            except ValueError:
                complete = False
            record['pss_kib'] = parse_pss(memory) if not memory_code else None
            record['write_bytes'] = parse_write_bytes(io) if not io_code else None
            after_stat_code, after_stat = self.capture(f'{prefix}-{process_id}-stat-after.txt',
                                                       ['shell', 'cat', f'/proc/{process_id}/stat'])
            try:
                if after_stat_code or parse_stat(after_stat, process_id)['start_ticks'] != record['start_ticks']:
                    complete = False
            except ValueError:
                complete = False
            if record['pss_kib'] is None:
                complete = False
            records.append(record)
        after_code, after_output = self.capture(prefix + '-processes-after.txt', ['shell', 'ps', '-A', '-n', '-o', 'PID,UID,NAME'])
        if after_code or parse_processes(after_output, self.package, uid) != processes:
            complete = False
        boot_code, boot_id = self.capture(prefix + '-boot.txt', ['shell', 'cat', '/proc/sys/kernel/random/boot_id'])
        service_code, service = self.capture(prefix + '-service.txt', ['shell', 'dumpsys', 'activity', 'services', self.package])
        page_code, activity = self.capture(prefix + '-activities.txt', ['shell', 'dumpsys', 'activity', 'activities'])
        page_closed = parse_page_closed(activity, self.package) if not page_code else None
        sample = dict(wall_seconds=wall, boot_id=boot_id.strip() if not boot_code else None,
                      complete=complete, processes=records, page_closed=page_closed,
                      service_foreground=not service_code and parse_receiver_foreground(service),
                      capture_span_seconds=time.monotonic() - started - wall)
        (self.destination / f'{prefix}-sample.json').write_text(json.dumps(sample, indent=2), encoding='utf-8')
        return sample


def collect(arguments):
    if not re.fullmatch(r'[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+', arguments.package):
        raise ValueError('Invalid package name.')
    if not 1 <= arguments.minutes <= 1440 or not 30 <= arguments.interval <= 3600 or not 0 <= arguments.warmup <= 3600:
        raise ValueError('Invalid duration, interval or warmup.')
    if not arguments.adb.is_file():
        raise ValueError('ADB executable does not exist.')
    state = subprocess.run([str(arguments.adb), '-s', arguments.serial, 'get-state'], capture_output=True, text=True, timeout=15)
    if state.returncode or state.stdout.strip() != 'device':
        raise ValueError('Selected device is not connected and authorized.')
    arguments.output.mkdir(parents=True, exist_ok=False)
    collector = Collector(arguments.adb, arguments.serial, arguments.package, arguments.output)
    package_code, package_info = collector.capture('package.txt', ['shell', 'dumpsys', 'package', arguments.package])
    match = re.search(r'(?:userId|appId)=(\d+)', package_info)
    if package_code or not match:
        raise ValueError('Cannot determine application UID; no sample collected.')
    if re.search(r'sharedUser(?:Id)?=', package_info):
        raise ValueError('Shared UID prevents exclusive application process accounting.')
    uid = int(match[1])
    user_code, current_user = collector.capture('current-user.txt', ['shell', 'am', 'get-current-user'])
    if user_code or not current_user.strip().isdigit():
        raise ValueError('Cannot determine current Android user; no sample collected.')
    uid = int(current_user.strip()) * 100000 + uid % 100000
    clock_code, clock_info = collector.capture('clock.txt', ['shell', 'getconf', 'CLK_TCK'])
    if clock_code or not clock_info.strip().isdigit() or int(clock_info.strip()) <= 0:
        raise ValueError('Cannot read kernel clock ticks; no CPU estimate collected.')
    ticks = int(clock_info.strip())
    collector.capture('device.txt', ['shell', 'getprop'])
    collector.context('before')
    print(f'Warmup {arguments.warmup}s; scenario={arguments.scenario}; output={arguments.output}', flush=True)
    time.sleep(arguments.warmup)
    started = time.monotonic()
    samples = []
    interrupted = False
    try:
        while True:
            sample = collector.sample(len(samples), uid, started)
            samples.append(sample)
            print(f'Sample {len(samples)}: complete={sample["complete"]}, processes={len(sample["processes"])}', flush=True)
            if arguments.scenario == 'idle-receiving' and (not sample['service_foreground'] or not sample['page_closed']):
                raise ValueError('Idle baseline requires a foreground receiver and its page closed. Enable receiving manually and return Home.')
            elapsed = time.monotonic() - started
            if sample['wall_seconds'] >= arguments.minutes * 60:
                break
            target = min(len(samples) * arguments.interval, arguments.minutes * 60)
            time.sleep(max(0, target - elapsed))
    except BaseException:
        interrupted = True
        raise
    finally:
        collector.context('after', samples[-1]['processes'] if samples else [])
        summary = summarize(samples, ticks, arguments.scenario, arguments.device_kind)
        summary['interrupted'] = interrupted
        summary['capture_failures'] = collector.failures
        summary['application_uid'] = uid
        summary['ticks_per_second'] = ticks
        summary['debuggable'] = bool(re.search(r'\bDEBUGGABLE\b', package_info))
        summary['user_declared_device_kind'] = True
        summary['requested_minutes'] = arguments.minutes
        summary['interval_seconds'] = arguments.interval
        summary['warmup_seconds'] = arguments.warmup
        summary['context_snapshots_only'] = ['battery', 'batterystats', 'netstats', 'process_fds']
        summary['limitations'] = 'ADB/dumpsys affects CPU and wakeups. Counters are sequential, not atomic; inspect capture span for timing uncertainty. Processes born and exited between samples are not observed. ADB reverse traffic is not device IP-layer capture. Disk I/O may be permission-denied. Redact raw system metadata before sharing. No final baseline or task pass is issued.'
        (arguments.output / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
        print(json.dumps(summary, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description='External Android cumulative resource sampler; never declares final acceptance.')
    commands = parser.add_subparsers(dest='command', required=True)
    collector = commands.add_parser('collect')
    collector.add_argument('--adb', type=Path, required=True)
    collector.add_argument('--serial', required=True)
    collector.add_argument('--package', default='dev.tug.tug_android')
    collector.add_argument('--output', type=Path, required=True)
    collector.add_argument('--minutes', type=int, default=30)
    collector.add_argument('--interval', type=int, default=60)
    collector.add_argument('--warmup', type=int, default=120)
    collector.add_argument('--scenario', choices=['idle-receiving', 'diagnostic'], default='idle-receiving')
    collector.add_argument('--device-kind', choices=['physical', 'emulator', 'unknown'], default='unknown')
    report = commands.add_parser('summarize')
    report.add_argument('directory', type=Path)
    report.add_argument('--scenario', choices=['idle-receiving', 'diagnostic'], default='diagnostic')
    report.add_argument('--device-kind', choices=['physical', 'emulator', 'unknown'], default='unknown')
    arguments = parser.parse_args()
    try:
        if arguments.command == 'collect':
            collect(arguments)
        else:
            previous_summary = json.loads((arguments.directory / 'summary.json').read_text(encoding='utf-8'))
            samples = [json.loads(file.read_text(encoding='utf-8')) for file in sorted(arguments.directory.glob('*-sample.json'))]
            print(json.dumps(summarize(samples, previous_summary['ticks_per_second'], arguments.scenario, arguments.device_kind), indent=2))
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
