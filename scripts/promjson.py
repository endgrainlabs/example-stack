"""Answers one question about a Prometheus API response read on standard input.

validate-stack.sh asks about scrape targets, recording rule values, alert rule
health, and firing alerts. Each answer is one line on standard output, so the
script can compare it with a string. Invoked as:

    curl ... | python3 scripts/promjson.py target-health go-api
"""

import json
import sys


def target_health(data, job):
    """up when every active target for the job is up, otherwise their healths."""
    targets = [
        t for t in data["data"]["activeTargets"] if t["labels"].get("job", "") == job
    ]
    if not targets:
        return "missing"
    healths = sorted({t["health"] for t in targets})
    return "up" if healths == ["up"] else ",".join(healths)


def target_count(data, job):
    """How many active targets carry the job label."""
    return str(
        len([t for t in data["data"]["activeTargets"] if t["labels"].get("job", "") == job])
    )


def query_value(data, _argument):
    """The first sample value of an instant query, or none."""
    result = data.get("data", {}).get("result", [])
    return result[0]["value"][1] if result else "none"


def rule_health(data, name):
    """The health Prometheus reports for a named alert rule."""
    rules = [
        r
        for group in data.get("data", {}).get("groups", [])
        for r in group.get("rules", [])
        if r.get("name") == name
    ]
    return rules[0].get("health", "missing") if rules else "missing"


def firing_alerts(data, _argument):
    """Every firing alert name, sorted, space separated."""
    return " ".join(
        sorted(
            {
                a["labels"]["alertname"]
                for a in data.get("data", {}).get("alerts", [])
                if a.get("state") == "firing"
            }
        )
    )


QUESTIONS = {
    "target-health": target_health,
    "target-count": target_count,
    "query-value": query_value,
    "rule-health": rule_health,
    "firing-alerts": firing_alerts,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in QUESTIONS:
        sys.stderr.write(
            "usage: promjson.py {%s} [argument]\n" % "|".join(sorted(QUESTIONS))
        )
        return 2
    argument = argv[2] if len(argv) > 2 else ""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write("promjson.py: standard input is not JSON\n")
        return 1
    try:
        print(QUESTIONS[argv[1]](data, argument))
    except (KeyError, IndexError, TypeError) as err:
        sys.stderr.write("promjson.py: unexpected response shape: %s\n" % err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
