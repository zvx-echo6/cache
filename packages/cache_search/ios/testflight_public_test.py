"""Tests for the build number handling in testflight_public.py. Standard library only, no network: python3 -I testflight_public_test.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testflight_public as tp  # noqa: E402


class FakeAsc:
    def __init__(self, versions):
        self.versions = versions

    def call(self, method, path):
        return 200, {"data": [{"attributes": {"version": v}} for v in self.versions], "links": {}}


class Failed(Exception):
    pass


def raising_fail(msg):
    raise Failed(msg)


class BuildNumbers(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(tp.parse_build("51"), (51, 0, 0))
        self.assertEqual(tp.parse_build("51.1"), (51, 1, 0))
        self.assertEqual(tp.parse_build("51.1.2"), (51, 1, 2))
        for bad in ("", "abc", "51.a", "51.", ".1", "51.1.1.1", "51..1", "-1", " 51", "5 1"):
            self.assertIsNone(tp.parse_build(bad), bad)

    def test_order(self):
        order = ["51", "51.1", "51.2", "51.10", "52"]
        parsed = [tp.parse_build(n) for n in order]
        self.assertEqual(parsed, sorted(parsed))
        self.assertEqual(len(set(parsed)), len(parsed))
        self.assertGreater(tp.parse_build("52"), tp.parse_build("51.9.9"))

    def test_highest_build(self):
        self.assertEqual(tp.highest_build(FakeAsc(["50", "51", "51.1", "abc"]), "app"), (51, 1, 0))
        self.assertEqual(tp.highest_build(FakeAsc(["50", "51", "51.1", "52"]), "app"), (52, 0, 0))
        self.assertEqual(tp.highest_build(FakeAsc(["abc"]), "app"), (0, 0, 0))

    def test_show(self):
        self.assertEqual(tp.show_build((51, 1, 0)), "51.1")
        self.assertEqual(tp.show_build((52, 0, 0)), "52")
        self.assertEqual(tp.show_build((51, 0, 3)), "51.0.3")

    def test_check_newer_refuses_bad_numbers(self):
        tp.fail = raising_fail
        for bad in ("51.1.1.1", "51.a"):
            with self.assertRaises(Failed):
                tp.check_newer(bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
