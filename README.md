# 🚀 zaml

Fast YAML 1.2 parsing library for Python 3.10+, written in Zig 🐍

zaml started as the proof of concept for Adam Serafini's PyCon DE 2022 talk
**Speeding Up Python with Zig** ([talk](https://2022.pycon.de/program/DFWSQR/),
[video](https://www.youtube.com/watch?v=O0MmmZxdct4)). This version targets
Zig 0.17 and current CPython. It is still experimental: see
[Limitations](#limitations).

- Full YAML 1.2 syntax via [yaml-zig](https://github.com/sakakibara/yaml-zig):
  block and flow collections, anchors, aliases, merge keys (`<<`), tags, and
  every scalar style including `|` and `>` block scalars.
- Pure Zig, importing `Python.h` directly: no FFI, `ctypes` or `cffi`.
- Built by the Zig toolchain alone. Zig comes from the
  [`ziglang`](https://pypi.org/project/ziglang/) PyPI package, so installing
  from source needs no separate Zig install.
- Built against the CPython stable ABI (`abi3`), so one build serves every
  CPython ≥ 3.10.
- Parses without holding the GIL.

## Usage

```python
import zaml

zaml.load("name: zaml\ntags: [fast, yaml]\nversion: 0.1")
# {'name': 'zaml', 'tags': ['fast', 'yaml'], 'version': 0.1}

zaml.load_all("---\na: 1\n---\nb: 2\n")
# [{'a': 1}, {'b': 2}]
```

`load` and `load_all` accept `str`, `bytes`, or a file object (anything with
`read()`). Invalid input raises `zaml.YAMLError`, a subclass of `ValueError`,
with the line and column.

Plain scalars are typed with the YAML 1.2
[core schema](https://yaml.org/spec/1.2.2/#1023-core-schema) by default:
`null`/`~`, `true`/`false`, decimal, `0o` octal and `0x` hex integers, floats,
`.inf` and `.nan`. Quoted scalars are always strings. Pass `schema=` to change
this:

| `schema` | Plain scalars |
| --- | --- |
| `"core"` (default) | YAML 1.2 core types; `yes`, `on`, `1_000` stay strings |
| `"yaml11"` | YAML 1.1 types, as PyYAML reads them: `yes`/`off` are booleans, `017` is octal, `1_000` is an int |
| `"json"` | JSON types only |
| `"failsafe"` | Everything is a string |

```python
zaml.load("debug: yes", schema="yaml11")  # {'debug': True}
```

## Development

```bash
uv venv --python 3.13
uv pip install . --group dev
pytest tests
```

`pip install .` runs `zig build` through `setup.py`. To build the extension by
hand:

```bash
python -m ziglang build -Doptimize=ReleaseFast -Dpython-include="$(python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')"
```

Set `ZIG=/path/to/zig` to build with a different Zig binary.

### Layout

| Path | Contents |
| --- | --- |
| `src/zaml.zig` | The extension module: parse with yaml-zig, then convert its values to Python objects |
| `src/python.h` | `Python.h` with the stable-ABI settings, translated to Zig by `build.zig` |
| `build.zig`, `build.zig.zon` | Build the shared library; `build.zig.zon` pins the yaml-zig commit |
| `setup.py` | setuptools `build_ext` that calls `zig build` |
| `tests/` | pytest suite |
| `benchmark/benchmark.py` | Comparison with PyYAML and ruamel.yaml |

## Benchmark

```bash
python benchmark/benchmark.py
```

Parsing a 1,000,000-key mapping (16.8 MB) on an Apple Silicon Mac, Python 3.13:

```text
zaml                     0.47 s
PyYAML CSafeLoader       5.45 s
ruamel.yaml (safe)      45.20 s
PyYAML SafeLoader       31.61 s
```

## Limitations

Differences from PyYAML's `safe_load`:

- Mapping keys that are lists or mappings (`? [a, b]`) raise `YAMLError`.
- Keys that are distinct in YAML but equal in Python (`1` and `true`) raise
  `YAMLError` as duplicates instead of silently overwriting.
- An alias produces a copy, not the same Python object as its anchor.
- Integers beyond 128 bits become floats.
- Unknown tags (`!foo`) keep the value as a string instead of raising.
- `schema="yaml11"` returns timestamps as strings, not `datetime`.
- `!!float 2` raises (a yaml-zig bug: an integer-looking value under
  `!!float` is rejected); `!!float 2.0` works.

The parser accepts a few invalid documents; yaml-zig lists them in its
[conformance notes](https://github.com/sakakibara/yaml-zig#conformance).
Documents nested deeper than 128 levels, or whose aliases expand to more than
1,000,000 nodes, raise `YAMLError`.

## Credits

Created by [Adam Serafini](https://github.com/adamserafini). Parsing by
[yaml-zig](https://github.com/sakakibara/yaml-zig); earlier versions used
[kubkon's](https://github.com/kubkon) [zig-yaml](https://codeberg.org/kubkon/zig-yaml).
