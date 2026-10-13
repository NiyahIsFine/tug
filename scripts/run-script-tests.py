import argparse
from pathlib import Path
import unittest


TESTS = Path(__file__).resolve().parent / "tests"
PLATFORMS = ("windows", "android", "server")


def build_suite(platform):
    directories = ("shared", *PLATFORMS) if platform == "all" else ("shared", platform)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for directory in directories:
        suite.addTests(loader.discover(str(TESTS / directory), top_level_dir=str(TESTS)))
    return suite


def main():
    parser = argparse.ArgumentParser(description="Run shared and selected platform script tests.")
    parser.add_argument("platform", choices=(*PLATFORMS, "all"))
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(build_suite(arguments.platform))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
