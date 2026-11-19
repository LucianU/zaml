"""Compare zaml with PyYAML (C and pure Python) and ruamel.yaml, loading and dumping.

Run from the repository root after installing zaml and the dev dependencies:

    python benchmark/benchmark.py
"""

import io
import time

import yaml as pyyaml
from ruamel.yaml import YAML

import zaml


def timed(label, func, arg):
    start = time.perf_counter()
    result = func(arg)
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

    print(f"\nDumping {len(data):,} keys\n")

    def ruamel_dump(d):
        out = io.StringIO()
        ruamel.dump(d, out)
        return out.getvalue()

    texts = [
        timed("zaml", zaml.dump, data),
        timed("PyYAML CSafeDumper", lambda d: pyyaml.dump(d, Dumper=pyyaml.CSafeDumper, sort_keys=False), data),
        timed("ruamel.yaml (safe)", ruamel_dump, data),
        timed("PyYAML SafeDumper", lambda d: pyyaml.dump(d, Dumper=pyyaml.SafeDumper, sort_keys=False), data),
    ]
    assert all(pyyaml.load(t, Loader=pyyaml.CSafeLoader) == data for t in texts)


if __name__ == "__main__":
    main()
