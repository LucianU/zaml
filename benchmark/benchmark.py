"""Compare zaml with PyYAML (C and pure Python) and ruamel.yaml.

Run from the repository root after installing zaml and the dev dependencies:

    python benchmark/benchmark.py
"""

import time

import yaml as pyyaml
from ruamel.yaml import YAML

import zaml


def timed(label, load, text):
    start = time.perf_counter()
    result = load(text)
    print(f"{label:<22} {time.perf_counter() - start:6.2f} s")
    return result


def main():
    # One million line YAML mapping.
    data = {f"a{i}": f"b{i + 1}" for i in range(1_000_000)}
    text = pyyaml.dump(data, Dumper=pyyaml.CSafeDumper)
    print(f"Parsing {len(text) / 1e6:.1f} MB, {len(data):,} keys\n")

    ruamel = YAML(typ="safe")
    results = [
        timed("zaml", zaml.load, text),
        timed("PyYAML CSafeLoader", lambda t: pyyaml.load(t, Loader=pyyaml.CSafeLoader), text),
        timed("ruamel.yaml (safe)", ruamel.load, text),
        timed("PyYAML SafeLoader", lambda t: pyyaml.load(t, Loader=pyyaml.SafeLoader), text),
    ]
    assert all(result == data for result in results)


if __name__ == "__main__":
    main()
