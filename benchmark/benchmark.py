"""Compare zaml's loading and dumping with other Python YAML libraries.

Run from the repository root:

    pip install . --group bench
    python benchmark/benchmark.py          # zaml, Rust-based libraries, PyYAML (C)
    python benchmark/benchmark.py --slow   # also pure-Python PyYAML and ruamel.yaml

Libraries that are not installed are skipped. Every result is checked: loaded
data must equal the input, and dumped YAML must read back equal with PyYAML,
which catches strings like "yes" that YAML 1.1 readers would turn into booleans.
"""

import argparse
import importlib
import io
import time
from collections.abc import Callable
from typing import Any

import yaml as pyyaml

import zaml

Load = Callable[[str], Any]
Dump = Callable[[Any], Any]
Library = tuple[str, Load, Dump]


def candidates(slow: bool) -> list[Library]:
    """(name, load, dump) for zaml, each installed alternative, and PyYAML."""
    libs: list[Library] = [("zaml", zaml.load, zaml.dump)]

    def optional(module, name, make):
        try:
            libs.append((name, *make(importlib.import_module(module))))
        except ImportError:
            pass

    optional("yamlrocks", "YAMLRocks", lambda m: (m.loads, m.dumps))
    optional("yaml_rs", "yaml-rs", lambda m: (m.loads, m.dumps))
    optional("yaml12", "py-yaml12", lambda m: (m.parse_yaml, m.format_yaml))
    optional("ryaml", "ryaml", lambda m: (m.loads, m.dumps))
    libs.append((
        "PyYAML (C)",
        lambda t: pyyaml.load(t, Loader=pyyaml.CSafeLoader),
        lambda d: pyyaml.dump(d, Dumper=pyyaml.CSafeDumper, sort_keys=False),
    ))
    if slow:
        libs.append((
            "PyYAML (Python)",
            lambda t: pyyaml.load(t, Loader=pyyaml.SafeLoader),
            lambda d: pyyaml.dump(d, Dumper=pyyaml.SafeDumper, sort_keys=False),
        ))

        def ruamel(m):
            yaml = m.YAML(typ="safe")

            def dump(d):
                out = io.StringIO()
                yaml.dump(d, out)
                return out.getvalue()

            return yaml.load, dump

        optional("ruamel.yaml", "ruamel.yaml", ruamel)
    return libs


def flat_document():
    """A 1,000,000-key mapping of short strings."""
    return {f"a{i}": f"b{i + 1}" for i in range(1_000_000)}


def config_document():
    """50,000 records mixing nested maps, lists, numbers, booleans, nulls and strings."""
    return {
        "records": [
            {
                "id": i,
                "name": f"service-{i}",
                "enabled": i % 3 != 0,
                "weight": i / 7,
                "owner": None if i % 5 == 0 else f"team-{i % 40}",
                "tags": ["alpha", "beta", f"t{i % 10}"],
                "limits": {"cpu": 0.5 + i % 4, "memory": f"{256 * (1 + i % 8)}Mi", "replicas": 1 + i % 5},
                "note": "yes" if i % 2 else "123",  # strings that must stay strings
            }
            for i in range(50_000)
        ]
    }


def best_of(runs: int, func: Callable[[Any], Any], arg: Any) -> tuple[float, Any]:
    """The fastest of `runs` calls, and the last result."""
    times: list[float] = []
    result: Any = None
    for _ in range(runs):
        start = time.perf_counter()
        result = func(arg)
        times.append(time.perf_counter() - start)
    return min(times), result


def measure(load: Load, dump: Dump, data: Any, text: str, runs: int) -> tuple[float, float, list[str]]:
    """Load and dump times, plus any correctness problems."""
    problems: list[str] = []
    load_time, loaded = best_of(runs, load, text)
    if loaded != data:
        problems.append("loaded data differs")
    dump_time, dumped = best_of(runs, dump, data)
    if pyyaml.load(dumped, Loader=pyyaml.CSafeLoader) != data:
        problems.append("PyYAML reads the dump back differently")
    return load_time, dump_time, problems


def report(title: str, data: Any, libs: list[Library], runs: int) -> None:
    text = pyyaml.dump(data, Dumper=pyyaml.CSafeDumper, sort_keys=False)
    print(f"\n{title} ({len(text) / 1e6:.1f} MB)\n")
    print(f"{'Library':<16} {'Load':>8} {'Dump':>8}")
    for name, load, dump in libs:
        slow = name in ("PyYAML (Python)", "ruamel.yaml")
        load_time, dump_time, problems = measure(load, dump, data, text, 1 if slow else runs)
        note = f"   {'; '.join(problems)}" if problems else ""
        print(f"{name:<16} {load_time:7.2f}s {dump_time:7.2f}s{note}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--slow", action="store_true", help="include pure-Python PyYAML and ruamel.yaml")
    parser.add_argument("--runs", type=int, default=3, help="runs per measurement; the fastest is reported")
    args = parser.parse_args()

    libs = candidates(args.slow)
    report("Flat mapping, 1,000,000 keys", flat_document(), libs, args.runs)
    report("Config-like, 50,000 records", config_document(), libs, args.runs)


if __name__ == "__main__":
    main()
