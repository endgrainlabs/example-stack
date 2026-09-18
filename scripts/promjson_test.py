"""Tests for promjson.py: one response shape per question, plus the error paths.

Run with: python3 -m unittest discover -s scripts -p 'promjson_test.py'
"""

import io
import json
import sys
import unittest

import promjson


def run(argv, payload, raw=False):
    """Runs main with argv and payload on stdin, JSON-encoded unless raw."""
    stdin, stdout, stderr = sys.stdin, sys.stdout, sys.stderr
    sys.stdin = io.StringIO(payload if raw else json.dumps(payload))
    sys.stdout, sys.stderr = io.StringIO(), io.StringIO()
    try:
        code = promjson.main(["promjson.py"] + argv)
        return code, sys.stdout.getvalue().strip(), sys.stderr.getvalue().strip()
    finally:
        sys.stdin, sys.stdout, sys.stderr = stdin, stdout, stderr


def targets(*pairs):
    return {"data": {"activeTargets": [{"labels": {"job": j}, "health": h} for j, h in pairs]}}


class TargetHealth(unittest.TestCase):
    def test_up_when_every_target_is_up(self):
        self.assertEqual(promjson.target_health(targets(("go-api", "up"), ("go-api", "up")), "go-api"), "up")

    def test_lists_healths_when_any_target_is_down(self):
        self.assertEqual(promjson.target_health(targets(("go-api", "up"), ("go-api", "down")), "go-api"), "down,up")

    def test_missing_when_no_target_carries_the_job(self):
        self.assertEqual(promjson.target_health(targets(("other", "up")), "go-api"), "missing")


class TargetCount(unittest.TestCase):
    def test_counts_only_the_job(self):
        self.assertEqual(promjson.target_count(targets(("a", "up"), ("a", "up"), ("b", "up")), "a"), "2")


class QueryValue(unittest.TestCase):
    def test_first_sample_value(self):
        data = {"data": {"result": [{"value": [1.0, "42"]}]}}
        self.assertEqual(promjson.query_value(data, ""), "42")

    def test_none_when_the_result_is_empty(self):
        self.assertEqual(promjson.query_value({"data": {"result": []}}, ""), "none")


class RuleHealth(unittest.TestCase):
    def test_named_rule(self):
        data = {"data": {"groups": [{"rules": [{"name": "A", "health": "ok"}, {"name": "B", "health": "err"}]}]}}
        self.assertEqual(promjson.rule_health(data, "B"), "err")

    def test_missing_rule(self):
        self.assertEqual(promjson.rule_health({"data": {"groups": []}}, "A"), "missing")


class FiringAlerts(unittest.TestCase):
    def test_sorted_unique_firing_names(self):
        data = {"data": {"alerts": [
            {"labels": {"alertname": "Z"}, "state": "firing"},
            {"labels": {"alertname": "A"}, "state": "firing"},
            {"labels": {"alertname": "A"}, "state": "firing"},
            {"labels": {"alertname": "P"}, "state": "pending"},
        ]}}
        self.assertEqual(promjson.firing_alerts(data, ""), "A Z")


class Main(unittest.TestCase):
    def test_answers_a_question(self):
        code, out, _ = run(["query-value"], {"data": {"result": [{"value": [0, "7"]}]}})
        self.assertEqual((code, out), (0, "7"))

    # The shell callers run `python3 promjson.py ... || echo "error"`, so a
    # failure must leave stdout empty or the fallback would append to partial
    # output. Every error-path test asserts that.
    def test_unknown_question_is_usage(self):
        code, out, err = run(["nonsense"], {})
        self.assertEqual((code, out), (2, ""))
        self.assertIn("usage", err)

    def test_non_json_input(self):
        code, out, err = run(["query-value"], "not json", raw=True)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("not JSON", err)

    def test_unexpected_shape(self):
        code, out, err = run(["target-health", "go-api"], {"data": {}})
        self.assertEqual((code, out), (1, ""))
        self.assertIn("unexpected response shape", err)

    def test_non_object_body(self):
        for body in ([], None, "text", 3):
            code, out, err = run(["target-health", "go-api"], body)
            self.assertEqual((code, out), (1, ""), body)
            self.assertIn("unexpected response shape", err)


if __name__ == "__main__":
    unittest.main()
