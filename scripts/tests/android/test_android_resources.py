import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import android_resources


def process(process_id=10, ticks=100, start=30, pss=1024, threads=3, writes=0):
    return dict(pid=process_id, cpu_ticks=ticks, start_ticks=start, pss_kib=pss,
                threads=threads, write_bytes=writes)


def sample(wall=0, processes=None, complete=True, boot='boot-1'):
    return dict(wall_seconds=wall, processes=processes if processes is not None else [process()],
                complete=complete, boot_id=boot, service_foreground=True, page_closed=True)


class ResourceParsingTests(unittest.TestCase):
    def test_processes_include_same_uid_and_named_isolated_children(self):
        text = 'PID UID NAME\n10 10051 dev.tug.tug_android\n11 10051 plugin_worker\n12 90011 dev.tug.tug_android:isolated\n13 10052 other\n'
        records = android_resources.parse_processes(text, 'dev.tug.tug_android', 10051)
        self.assertEqual([record['pid'] for record in records], [10, 11, 12])

    def test_stat_parses_names_with_spaces_and_parentheses(self):
        fields = ['S'] + ['0'] * 21
        fields[11], fields[12], fields[17], fields[19] = '12', '34', '5', '456'
        record = android_resources.parse_stat('10 (a ) tricky name) ' + ' '.join(fields), 10)
        self.assertEqual(record, dict(cpu_ticks=46, threads=5, start_ticks=456))
        with self.assertRaises(ValueError):
            android_resources.parse_stat('11 (name) S 1', 10)

    def test_pss_parses_summary_and_old_total_layout_without_using_rss(self):
        self.assertEqual(android_resources.parse_pss('TOTAL PSS: 73465 TOTAL RSS: 196680'), 73465)
        self.assertEqual(android_resources.parse_pss('  TOTAL 1234 9999 8888\n'), 1234)
        self.assertIsNone(android_resources.parse_pss('Permission denied'))

    def test_io_permission_denied_is_not_zero_disk_writes(self):
        self.assertIsNone(android_resources.parse_write_bytes('Permission denied'))
        self.assertEqual(android_resources.parse_write_bytes('write_bytes: 42\n'), 42)

    def test_page_state_requires_a_known_resumed_activity(self):
        package = 'dev.tug.tug_android'
        self.assertIsNone(android_resources.parse_page_closed('unrecognized output', package))
        self.assertFalse(android_resources.parse_page_closed('ResumedActivity: u0 ' + package + '/.MainActivity', package))
        self.assertFalse(android_resources.parse_page_closed('mResumedActivity = u0 ' + package + '/.MainActivity', package))
        self.assertTrue(android_resources.parse_page_closed('topResumedActivity= u0 other/.Home', package))
        self.assertTrue(android_resources.parse_page_closed('topResumedActivity= u0 ' + package + 'other/.Main', package))

    def test_foreground_flag_must_belong_to_the_receiver(self):
        receiver = 'com.pravera.flutter_foreground_task.service.ForegroundService'
        self.assertTrue(android_resources.parse_receiver_foreground('ServiceRecord{' + receiver + '}\nisForeground=true'))
        self.assertFalse(android_resources.parse_receiver_foreground('ServiceRecord{' + receiver + '}\nisForeground=false\nServiceRecord{other}\nisForeground=true'))
        self.assertFalse(android_resources.parse_receiver_foreground('(nothing)'))


class ResourceSummaryTests(unittest.TestCase):
    def report(self, samples, kind='emulator', scenario='diagnostic'):
        return android_resources.summarize(samples, 100, scenario, kind)

    def test_aggregates_multiple_processes_and_cpu_against_single_core(self):
        before = sample(processes=[process(), process(11, pss=2048)])
        after = sample(60, [process(ticks=110, writes=12), process(11, ticks=120, pss=3072, writes=5)])
        report = self.report([before, after])
        self.assertAlmostEqual(report['mean_cpu_percent_one_core'], 0.5)
        self.assertEqual(report['cumulative_cpu_seconds'], 0.3)
        self.assertEqual(report['peak_total_pss_mib'], 4)
        self.assertEqual(report['disk_write_bytes'], 17)
        self.assertEqual(report['max_threads'], 6)

    def test_stopped_or_short_emulator_run_cannot_qualify_as_baseline(self):
        report = self.report([sample(), sample(60, [process(ticks=101)])])
        self.assertIn('not_a_physical_device', report['baseline_eligibility_issues'])
        self.assertIn('diagnostic_not_idle_receiving', report['baseline_eligibility_issues'])
        self.assertIn('less_than_30_minutes', report['baseline_eligibility_issues'])
        self.assertEqual(report['verdict'], 'exploratory_measurement_not_final_acceptance')

    def test_process_birth_death_reboot_and_pid_reuse_exclude_intervals(self):
        cases = [sample(60, []), sample(60, [process(), process(11)]),
                 sample(60, [process(start=99)]), sample(60, boot='boot-2')]
        for after in cases:
            with self.subTest(after=after):
                report = self.report([sample(), after])
                self.assertFalse(report['measurement_complete'])
                self.assertIsNone(report['mean_cpu_percent_one_core'])
                self.assertEqual(report['covered_wall_seconds'], 0)

    def test_invalid_counters_do_not_count_as_idle_zero(self):
        cases = [sample(60, [process(ticks=10)]), sample(60, complete=False)]
        for key in ['cpu_ticks', 'start_ticks', 'pss_kib', 'threads']:
            missing = process()
            missing[key] = None
            cases.append(sample(60, [missing]))
        for after in cases:
            with self.subTest(after=after):
                report = self.report([sample(), after])
                self.assertFalse(report['measurement_complete'])
                self.assertIsNone(report['mean_cpu_percent_one_core'])

    def test_unreliable_disk_counters_are_unknown(self):
        cases = [
            [sample(), sample(60, [process(writes=None)])],
            [sample(0, [process(writes=100)]), sample(30, [process(writes=90)]),
             sample(60, [process(writes=110)])],
        ]
        for samples in cases:
            with self.subTest(samples=samples):
                report = self.report(samples)
                self.assertIsNone(report['disk_write_bytes'])

    def test_long_physical_run_still_does_not_claim_traffic_or_full_acceptance(self):
        report = self.report([sample(), sample(1800)], kind='physical', scenario='idle-receiving')
        self.assertEqual(report['baseline_eligibility_issues'], [])
        self.assertIn('bidirectional_ip_traffic', report['unverified'])
        self.assertEqual(report['verdict'], 'exploratory_measurement_not_final_acceptance')

    def test_empty_samples_and_invalid_clock_are_explicit(self):
        self.assertIsNone(self.report([])['peak_total_pss_mib'])
        for clock in (0, float('nan'), float('inf')):
            with self.subTest(clock=clock), self.assertRaises(ValueError):
                android_resources.summarize([], clock, 'diagnostic', 'unknown')
        for wall in (float('nan'), float('inf')):
            with self.subTest(wall=wall), self.assertRaises(ValueError):
                self.report([sample(wall)])

    def test_open_page_or_stopped_service_is_not_idle_receiving(self):
        for field in ['service_foreground', 'page_closed']:
            after = sample(1800)
            after[field] = False
            report = self.report([sample(), after], kind='physical', scenario='idle-receiving')
            self.assertIn('foreground_receiver_or_closed_page_not_verified', report['baseline_eligibility_issues'])


class ResourceCollectionTests(unittest.TestCase):
    def test_pid_reuse_during_sample_is_incomplete_and_unknown_page_stays_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            collector = android_resources.Collector('adb', 'device', 'dev.tug.tug_android', Path(temporary))
            fields = ['0'] * 22
            fields[0], fields[11], fields[12], fields[17], fields[19] = 'S', '100', '20', '3', '30'
            before = '10 (app) ' + ' '.join(fields)
            fields[19] = '40'
            after = '10 (app) ' + ' '.join(fields)
            replies = {
                '00000-processes.txt': '10 10051 dev.tug.tug_android',
                '00000-processes-after.txt': '10 10051 dev.tug.tug_android',
                '00000-10-stat.txt': before, '00000-10-stat-after.txt': after,
                '00000-10-meminfo.txt': 'TOTAL PSS: 1024', '00000-10-io.txt': 'Permission denied',
                '00000-boot.txt': 'boot-1',
            }
            with patch.object(collector, 'capture', side_effect=lambda name, args: (0, replies.get(name, ''))):
                captured = collector.sample(0, 10051, android_resources.time.monotonic())
            self.assertFalse(captured['complete'])
            self.assertIsNone(captured['page_closed'])
            self.assertIsNone(captured['processes'][0]['write_bytes'])
            self.assertTrue((Path(temporary) / '00000-sample.json').is_file())

    def test_short_collection_preserves_endpoints_and_context_without_mutations(self):
        with tempfile.TemporaryDirectory() as temporary:
            adb = Path(temporary) / 'adb.exe'
            adb.touch()
            arguments = argparse.Namespace(adb=adb, serial='device', output=Path(temporary) / 'evidence',
                                           package='dev.tug.tug_android', minutes=1, interval=30,
                                           warmup=0, scenario='diagnostic', device_kind='emulator')
            replies = {'package.txt': 'appId=10051', 'current-user.txt': '0', 'clock.txt': '100'}
            samples = [sample(0), sample(30), sample(60)]
            with patch.object(android_resources.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'device', '')), \
                    patch.object(android_resources.Collector, 'capture', side_effect=lambda name, args: (0, replies.get(name, ''))), \
                    patch.object(android_resources.Collector, 'sample', side_effect=samples) as captures, \
                    patch.object(android_resources.Collector, 'context') as context, \
                    patch.object(android_resources.time, 'sleep'), patch('builtins.print'):
                android_resources.collect(arguments)
            report = android_resources.json.loads((arguments.output / 'summary.json').read_text())
            self.assertEqual(captures.call_count, 3)
            self.assertEqual(context.call_count, 2)
            self.assertEqual(report['wall_seconds'], 60)
            self.assertEqual(report['verdict'], 'exploratory_measurement_not_final_acceptance')
            self.assertFalse(report['interrupted'])

    def test_rejected_idle_collection_keeps_summary_and_does_not_start_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            adb = Path(temporary) / 'adb.exe'
            adb.touch()
            arguments = argparse.Namespace(adb=adb, serial='device', output=Path(temporary) / 'evidence',
                                           package='dev.tug.tug_android', minutes=1, interval=30,
                                           warmup=0, scenario='idle-receiving', device_kind='emulator')
            stopped = sample()
            stopped['service_foreground'] = False
            replies = {'package.txt': 'appId=10051', 'current-user.txt': '0', 'clock.txt': '100'}
            with patch.object(android_resources.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'device', '')), \
                    patch.object(android_resources.Collector, 'capture', side_effect=lambda name, args: (0, replies.get(name, ''))), \
                    patch.object(android_resources.Collector, 'sample', return_value=stopped) as captures, \
                    patch.object(android_resources.Collector, 'context'), \
                    patch.object(android_resources.time, 'sleep'), patch('builtins.print'):
                with self.assertRaisesRegex(ValueError, 'Enable receiving manually'):
                    android_resources.collect(arguments)
            report = android_resources.json.loads((arguments.output / 'summary.json').read_text())
            self.assertEqual(captures.call_count, 1)
            self.assertTrue(report['interrupted'])
            self.assertFalse(report['measurement_complete'])

    def test_offline_device_is_rejected_before_creating_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            adb = Path(temporary) / 'adb.exe'
            adb.touch()
            output = Path(temporary) / 'evidence'
            arguments = argparse.Namespace(adb=adb, serial='offline', output=output,
                                           package='dev.tug.tug_android', minutes=1, interval=30,
                                           warmup=0, scenario='diagnostic', device_kind='emulator')
            with patch.object(android_resources.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'offline')):
                with self.assertRaises(ValueError):
                    android_resources.collect(arguments)
            self.assertFalse(output.exists())

    def test_invalid_package_is_rejected_without_shell_execution(self):
        arguments = argparse.Namespace(package='app;rm -rf /')
        with patch.object(android_resources.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                android_resources.collect(arguments)
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
