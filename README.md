# 🚀 zaml

**Fast YAML for Python, written in Zig.** zaml reads YAML about 11× faster
than PyYAML's C loader, and writes it about 24× faster, using plain Python
dicts, lists, strings and numbers.

```python
import zaml

config = zaml.load("""
server:
  host: localhost
  ports: [8080, 8443]
debug: false
""")
# {'server': {'host': 'localhost', 'ports': [8080, 8443]}, 'debug': False}

print(zaml.dump(config))
# server:
#   host: localhost
#   ports:
#     - 8080
#     - 8443
# debug: false
```

zaml is experimental: see [Differences from PyYAML](#differences-from-pyyaml).

## Quick start

zaml is not on PyPI. Install it from GitHub (Python 3.10 or newer):

```bash
pip install git+https://github.com/LucianU/zaml
```

pip builds zaml from source, downloading the Zig compiler (about 100 MB)
along the way, so the first install can take a while on a slow connection.
You don't need Zig or a C compiler installed.

To depend on zaml in your own project, add it to `pyproject.toml`:

```toml
dependencies = ["zaml @ git+https://github.com/LucianU/zaml"]
```

Then load a file:

```python
import zaml

with open("config.yaml", encoding="utf-8") as f:
    config = zaml.load(f)
```

## Switching from PyYAML

| PyYAML | zaml |
| --- | --- |
| `yaml.safe_load(stream)` | `zaml.load(stream)` |
| `yaml.safe_load_all(stream)` | `zaml.load_all(stream)` (returns a list, not a generator) |
| `yaml.safe_dump(data, stream)` | `zaml.dump(data, stream)` |
| `yaml.safe_dump_all(documents, stream)` | `zaml.dump_all(documents, stream)` |
| `except yaml.YAMLError` | `except zaml.YAMLError` |

One difference matters for most files: zaml follows YAML 1.2, while PyYAML
follows YAML 1.1. Under YAML 1.2, `yes`, `no`, `on` and `off` are strings,
not booleans. If your files rely on the old behavior, pass
`schema="yaml11"`:

```python
zaml.load("debug: yes")                   # {'debug': 'yes'}
zaml.load("debug: yes", schema="yaml11")  # {'debug': True}
```

See [Differences from PyYAML](#differences-from-pyyaml) for the rest.

## Usage

### Loading documents

```python
zaml.load(stream, *, schema="core")      # the first document
zaml.load_all(stream, *, schema="core")  # every document, as a list
```

`stream` can be a `str`, `bytes`, or a file object (anything with a `read()`
method). A stream with several documents separated by `---` gives one list
item per document with `load_all`; `load` returns only the first. An empty
stream loads as `None`.

```python
zaml.load_all("---\nname: alice\n---\nname: bob\n")
# [{'name': 'alice'}, {'name': 'bob'}]
```

### What you get back

| YAML | Python |
| --- | --- |
| mapping (`key: value`, `{a: 1}`) | `dict` |
| sequence (`- item`, `[1, 2]`) | `list` |
| `null`, `~`, or an empty value | `None` |
| `true`, `false` | `bool` |
| `42`, `0x2A`, `0o52` | `int` |
| `3.14`, `1e-3`, `.inf`, `.nan` | `float` |
| anything else, and every quoted value | `str` |

Quoted values are always strings: `"123"` stays `'123'`.

zaml understands the whole YAML 1.2 syntax: block and flow collections,
anchors and aliases (`&name`, `*name`), merge keys (`<<: *defaults`), tags
(`!!str 123`), and multi-line strings (`|` and `>`).

### Schemas

The `schema` argument decides how unquoted values are typed:

| `schema` | Unquoted values |
| --- | --- |
| `"core"` (default) | YAML 1.2 types, as in the table above |
| `"yaml11"` | YAML 1.1 types, like PyYAML: `yes`/`off` are booleans, `017` is octal, `1_000` is an int |
| `"json"` | JSON types only |
| `"failsafe"` | Everything is a string |

### Errors

Invalid YAML raises `zaml.YAMLError`, a subclass of `ValueError`, with the
line and column of the problem:

```python
zaml.load("tags: [fast, yaml\n")
# zaml.YAMLError: unterminated flow sequence (line 2, column 1)

zaml.load("a: 1\na: 2\n")
# zaml.YAMLError: duplicate mapping key: 'a'
```

### Writing YAML

```python
zaml.dump(data, stream=None, *, indent=2, sort_keys=False)
zaml.dump_all(documents, stream=None, *, indent=2, sort_keys=False)
```

`dump` returns the YAML as a `str`, or writes it to `stream` (anything with a
`write()` method, such as a file opened in text mode) and returns `None`.
`dump_all` writes several documents separated by `---`.

```python
with open("config.yaml", "w", encoding="utf-8") as f:
    zaml.dump(config, f)
```

zaml writes `dict`, `list`, `tuple`, `str`, `int`, `float`, `bool` and `None`;
any other type raises `TypeError`. Keys stay in the dict's order unless you
pass `sort_keys=True`. Strings that would read back as something else are
quoted, so `"yes"`, `"123"` and `"null"` stay strings, also for PyYAML.

## Performance

Reading and writing a 1,000,000-key mapping (16.8 MB of YAML) on an Apple
Silicon Mac, Python 3.13:

| Library | Read | Write |
| --- | --- | --- |
| **zaml** | **0.44 s** | **0.17 s** |
| PyYAML (C) | 5.35 s | 4.10 s |
| PyYAML (pure Python) | 31.20 s | 18.11 s |
| ruamel.yaml (safe) | 44.22 s | 31.36 s |

zaml also lets other Python threads run while it parses. To run the benchmark
yourself, see [Development](#development).

## Differences from PyYAML

Compared with PyYAML's `safe_load`:

- `yes`, `no`, `on`, `off` are strings, and `1_000` is a string, unless you
  pass `schema="yaml11"`.
- A key that appears twice raises `YAMLError` instead of silently keeping the
  last value. This includes keys that differ in YAML but are equal in Python,
  such as `1` and `true`.
- Lists or mappings used as keys (`? [a, b]`) raise `YAMLError`.
- An alias gives a copy of its anchor's value, not the same Python object.
- Dates stay strings, even with `schema="yaml11"`.
- Unknown tags (`!foo`) are ignored, and the value is kept as a string.
- Integers wider than 128 bits become floats.
- `!!float 2` raises because of a bug in the parser; `!!float 2.0` works.

When writing:

- Output is always in block style; there is no compact `{a: 1}` form.
- Dates, `bytes` and `set` raise `TypeError`; convert them first, for example
  with `date.isoformat()`.
- An object that appears twice is written out twice, not as an anchor and
  alias.
- Data that contains itself raises `ValueError`.

zaml also rejects documents nested more than 128 levels deep, and aliases that
expand to more than 1,000,000 values, which protects against
["billion laughs"](https://en.wikipedia.org/wiki/Billion_laughs_attack) inputs.
A few invalid documents are still accepted; the parser lists them in its
[conformance notes](https://github.com/sakakibara/yaml-zig#conformance).

## How it works

zaml is a CPython extension written in Zig. It parses with
[yaml-zig](https://github.com/sakakibara/yaml-zig), then converts the result
into Python objects; writing goes the other way, through yaml-zig's emitter. It imports `Python.h` directly, with no `ctypes` or
`cffi`, and builds against the CPython stable ABI, so one build works on every
Python from 3.10 on. The Zig compiler comes from the
[`ziglang`](https://pypi.org/project/ziglang/) package on PyPI.

## Development

```bash
git clone https://github.com/LucianU/zaml
cd zaml
uv venv --python 3.13
uv pip install . --group dev
pytest tests
python benchmark/benchmark.py
```

`pip install .` runs `zig build` through `setup.py`. To build the extension by
hand:

```bash
python -m ziglang build -Doptimize=ReleaseFast -Dpython-include="$(python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')"
```

Set `ZIG=/path/to/zig` to build with a different Zig binary.

| Path | Contents |
| --- | --- |
| `src/zaml.zig` | The extension module: parse with yaml-zig, then convert its values to Python objects |
| `src/python.h` | `Python.h` with the stable-ABI settings, translated to Zig by `build.zig` |
| `build.zig`, `build.zig.zon` | Build the shared library; `build.zig.zon` pins the yaml-zig commit |
| `setup.py` | setuptools `build_ext` that calls `zig build` |
| `tests/` | pytest suite |
| `benchmark/benchmark.py` | Comparison with PyYAML and ruamel.yaml |

CI runs the tests on Linux and Windows for every push. Wheels for all
platforms build on a release, or from **Run workflow** in the Actions tab.

## Credits

zaml was created by [Adam Serafini](https://github.com/adamserafini) as the
proof of concept for his PyCon DE 2022 talk **Speeding Up Python with Zig**
([talk](https://2022.pycon.de/program/DFWSQR/),
[video](https://www.youtube.com/watch?v=O0MmmZxdct4)); the original is at
[adamserafini/zaml](https://github.com/adamserafini/zaml). This fork rebuilds
it on Zig 0.17. Parsing is done by
[yaml-zig](https://github.com/sakakibara/yaml-zig); earlier versions used
[kubkon's](https://github.com/kubkon) [zig-yaml](https://codeberg.org/kubkon/zig-yaml).
