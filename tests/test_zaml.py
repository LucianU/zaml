import math
import textwrap

import pytest
import yaml as pyyaml

import zaml


def load(text):
    return zaml.load(textwrap.dedent(text))


def test_simple_mapping():
    assert zaml.load("a0: b1") == {"a0": "b1"}


def test_nested_structures():
    doc = load(
        """
        name: zaml
        tags: [fast, yaml]
        owner:
          languages:
            - zig
            - python
        """
    )
    assert doc == {
        "name": "zaml",
        "tags": ["fast", "yaml"],
        "owner": {"languages": ["zig", "python"]},
    }


def test_bytes_input():
    assert zaml.load(b"key: value") == {"key": "value"}


def test_unicode():
    assert zaml.load("café: naïve ☕") == {"café": "naïve ☕"}


def test_empty_document_is_none():
    assert zaml.load("") is None


def test_empty_value_is_none():
    assert zaml.load("a:\nb: 1") == {"a": None, "b": 1}


@pytest.mark.parametrize(
    "scalar, expected",
    [
        ("~", None),
        ("null", None),
        ("NULL", None),
        ("true", True),
        ("False", False),
        ("0", 0),
        ("-17", -17),
        ("+42", 42),
        ("007", 7),
        ("0o17", 15),
        ("0x1F", 31),
        ("123456789012345678901234567890", 123456789012345678901234567890),
        ("1.5", 1.5),
        ("-0.25", -0.25),
        (".5", 0.5),
        ("1.", 1.0),
        ("6.02e23", 6.02e23),
        ("1e-3", 0.001),
        (".inf", math.inf),
        ("-.Inf", -math.inf),
        ("hello", "hello"),
        ("yes", "yes"),  # YAML 1.1 boolean, a string in YAML 1.2
        ("1_000", "1_000"),
        ("0x", "0x"),
        ("1.2.3", "1.2.3"),
        ("e5", "e5"),
        ("-x", "-x"),
    ],
)
def test_core_schema(scalar, expected):
    value = zaml.load(f"k: {scalar}")["k"]
    assert value == expected
    assert type(value) is type(expected)


def test_nan():
    assert math.isnan(zaml.load("k: .nan")["k"])


def test_quoted_scalars_stay_strings():
    doc = load(
        """
        a: "123"
        b: 'true'
        c: "null"
        d: "tab\\there"
        e: 'it''s'
        """
    )
    assert doc == {"a": "123", "b": "true", "c": "null", "d": "tab\there", "e": "it's"}


def test_typed_keys():
    assert zaml.load("1: one\nfalse: no\n2.5: x") == {1: "one", False: "no", 2.5: "x"}


def test_keys_equal_in_python_are_duplicates():
    # true == 1 in Python, so these two keys would silently collapse into one.
    with pytest.raises(zaml.YAMLError, match="duplicate"):
        zaml.load("1: one\ntrue: yes")


def test_parse_error_reports_position():
    with pytest.raises(zaml.YAMLError, match=r"line \d+, column \d+"):
        zaml.load("- a\nb: 1\n")


def test_empty_values_between_keys():
    doc = load(
        """
        a:
        b:
          c:
          d: 1
        e:
        - x
        f:
        """
    )
    assert doc == {"a": None, "b": {"c": None, "d": 1}, "e": ["x"], "f": None}


def test_load_all():
    docs = zaml.load_all("---\na: 1\n---\nb: 2\n")
    assert docs == [{"a": 1}, {"b": 2}]


def test_load_returns_first_document():
    assert zaml.load("---\na: 1\n---\nb: 2\n") == {"a": 1}


def test_duplicate_key_raises():
    with pytest.raises(zaml.YAMLError, match="duplicate"):
        zaml.load("a: 1\na: 2")


def test_parse_error_raises():
    with pytest.raises(zaml.YAMLError):
        zaml.load("a: [1, 2")


def test_flow_sequences():
    assert zaml.load('a: [[1, 2], [x, "y"]]') == {"a": [[1, 2], ["x", "y"]]}


def test_flow_mappings():
    assert zaml.load("a: {b: 1, c: [2, {d: e}]}\nf: {}") == {"a": {"b": 1, "c": [2, {"d": "e"}]}, "f": {}}


def test_anchors_and_aliases():
    doc = load(
        """
        base: &base {x: 1}
        copy: *base
        list: [&v 3, *v]
        """
    )
    assert doc == {"base": {"x": 1}, "copy": {"x": 1}, "list": [3, 3]}


def test_merge_keys():
    doc = load(
        """
        defaults: &defaults
          adapter: postgres
          host: localhost
        development:
          <<: *defaults
          host: dev.example.com
        """
    )
    assert doc["development"] == {"adapter": "postgres", "host": "dev.example.com"}


def test_tags():
    assert zaml.load("a: !!str 1\nb: !!float 2.5\nc: !!int '3'\nd: !local x") == {"a": "1", "b": 2.5, "c": 3, "d": "x"}


@pytest.mark.xfail(reason="yaml-zig 0.6.0 rejects an integer-looking scalar under !!float", strict=True)
def test_float_tag_on_integer():
    assert zaml.load("a: !!float 2") == {"a": 2.0}


def test_block_scalars():
    doc = load(
        """
        literal: |
          line one
          line two
        folded: >
          folded
          text

          new paragraph
        stripped: |-
          no trailing newline
        kept: |+
          keep

        end: 1
        """
    )
    assert doc == {
        "literal": "line one\nline two\n",
        "folded": "folded text\nnew paragraph\n",
        "stripped": "no trailing newline",
        "kept": "keep\n\n",
        "end": 1,
    }


def test_multiline_plain_and_quoted_scalars():
    doc = load(
        """
        plain: this is
          one string
        quoted: "spans
          lines"
        """
    )
    assert doc == {"plain": "this is one string", "quoted": "spans lines"}


def test_double_quoted_escapes():
    assert zaml.load(r'a: "back\\slash \x41 é \U0001F600 \0end"') == {"a": "back\\slash A é 😀 \0end"}


def test_complex_keys_raise():
    with pytest.raises(zaml.YAMLError, match="keys"):
        zaml.load("? [a, b]\n: value")


@pytest.mark.parametrize("source", ["a: b: c", "a: 1\n  b: 2\n", "key: 'unterminated"])
def test_invalid_documents_raise(source):
    with pytest.raises(zaml.YAMLError):
        zaml.load(source)


def test_yaml11_schema():
    doc = zaml.load("a: yes\nb: off\nc: 0o17\nd: 017\ne: 1_000", schema="yaml11")
    assert doc == {"a": True, "b": False, "c": "0o17", "d": 15, "e": 1000}
    assert zaml.load("a: yes", schema="core") == {"a": "yes"}


def test_json_and_failsafe_schemas():
    assert zaml.load("a: 1", schema="failsafe") == {"a": "1"}
    assert zaml.load("a: [1, true, null]", schema="json") == {"a": [1, True, None]}


def test_unknown_schema_raises():
    with pytest.raises(ValueError, match="schema"):
        zaml.load("a: 1", schema="yaml13")  # pyright: ignore[reportArgumentType]


def test_file_objects(tmp_path):
    path = tmp_path / "doc.yaml"
    path.write_text("a: 1\n", encoding="utf-8")
    with open(path, encoding="utf-8") as f:
        assert zaml.load(f) == {"a": 1}
    with open(path, "rb") as f:
        assert zaml.load_all(f) == [{"a": 1}]


def test_file_object_returning_wrong_type():
    class Reader:
        def read(self):
            return 42

    with pytest.raises(TypeError, match="read"):
        zaml.load(Reader())  # pyright: ignore[reportArgumentType]


def test_yaml_error_is_value_error():
    assert issubclass(zaml.YAMLError, ValueError)


def test_wrong_type_raises():
    with pytest.raises(TypeError):
        zaml.load(42)  # pyright: ignore[reportArgumentType]


def test_matches_pyyaml_on_large_mapping():
    data = {f"a{i}": f"b{i + 1}" for i in range(10_000)}
    text = pyyaml.dump(data, Dumper=pyyaml.SafeDumper)
    assert zaml.load(text) == pyyaml.safe_load(text) == data


# ---------------------------------------------------------------------------
# Dumping

import collections
import datetime
import io

DUMP_CASES = [
    None,
    True,
    0,
    -17,
    2**64,
    -(2**127),
    1.5,
    float("inf"),
    "plain",
    "",
    [],
    {},
    [1, [2, [3, []]], {}],
    {"a": {"b": {"c": [1, 2, {"d": None}]}}},
    {2: "int", 2.5: "float", True: "bool", None: "none", "s": "str"},
    # Strings that would read back as something else unless quoted.
    ["yes", "no", "on", "off", "true", "null", "~", "123", "0x1F", "1e3", ".inf", "1_000", "2026-11-19"],
    # Strings with YAML syntax, whitespace and non-ASCII.
    ["a: b", "- x", "#c", "&a", "*a", "!t", "|", ">", "{", "[", " lead", "trail ", "multi\nline\n", "tab\there", "café ☕"],
]


@pytest.mark.parametrize("data", DUMP_CASES, ids=range(len(DUMP_CASES)))
def test_dump_round_trip(data):
    text = zaml.dump(data)
    assert zaml.load(text) == data
    assert pyyaml.safe_load(text) == data


def test_dump_output_shape():
    assert zaml.dump({"name": "zaml", "tags": ["fast", "yaml"]}) == "name: zaml\ntags:\n  - fast\n  - yaml\n"


def test_dump_keeps_order_unless_sorted():
    data = {"b": 1, "a": 2}
    assert zaml.dump(data) == "b: 1\na: 2\n"
    assert zaml.dump(data, sort_keys=True) == "a: 2\nb: 1\n"


def test_dump_indent():
    assert zaml.dump({"a": {"b": 1}}, indent=4) == "a:\n    b: 1\n"
    with pytest.raises(ValueError, match="indent"):
        zaml.dump({}, indent=0)


def test_dump_nan():
    assert math.isnan(zaml.load(zaml.dump(float("nan"))))


def test_dump_tuples_and_dict_subclasses():
    data = collections.OrderedDict(a=(1, 2))
    assert zaml.load(zaml.dump(data)) == {"a": [1, 2]}


def test_dump_to_stream():
    out = io.StringIO()
    assert zaml.dump({"a": 1}, out) is None
    assert out.getvalue() == "a: 1\n"


def test_dump_all():
    docs = [{"a": 1}, [2], "three"]
    text = zaml.dump_all(docs)
    assert text.count("---") == 2
    assert zaml.load_all(text) == docs
    assert list(pyyaml.safe_load_all(text)) == docs
    assert zaml.dump_all(iter(docs)) == text
    assert zaml.dump_all([]) == ""


@pytest.mark.parametrize(
    "data",
    [{1, 2}, b"bytes", datetime.date(2026, 11, 19), object(), {"a": [complex(1, 2)]}],
    ids=["set", "bytes", "date", "object", "nested-complex"],
)
def test_dump_unsupported_types(data):
    with pytest.raises(TypeError, match="cannot dump"):
        zaml.dump(data)


def test_dump_collection_keys():
    with pytest.raises(TypeError, match="mapping keys"):
        zaml.dump({(1, 2): "tuple key"})


def test_dump_self_reference():
    data = []
    data.append(data)
    with pytest.raises(ValueError, match="contains itself"):
        zaml.dump(data)


def test_dump_too_deep():
    data = []
    for _ in range(200):
        data = [data]
    with pytest.raises(ValueError, match="nested"):
        zaml.dump(data)


def test_dump_huge_int():
    with pytest.raises(ValueError, match="128 bits"):
        zaml.dump(2**200)


def test_dump_unencodable_string():
    with pytest.raises(UnicodeEncodeError):
        zaml.dump("\ud800")


# ---------------------------------------------------------------------------
# dump(default=...)

import decimal
import enum
import pathlib


def test_default_converts_unsupported_values():
    data = {
        "when": datetime.date(2026, 11, 19),
        "price": decimal.Decimal("9.99"),
        "path": pathlib.PurePosixPath("/etc/zaml.yaml"),
    }
    assert zaml.load(zaml.dump(data, default=str)) == {"when": "2026-11-19", "price": "9.99", "path": "/etc/zaml.yaml"}


def test_default_can_return_collections():
    class Color(enum.Enum):
        RED = 1

    def default(obj):
        if isinstance(obj, set):
            return sorted(obj)
        if isinstance(obj, Color):
            return {"color": obj.name}
        raise TypeError(f"unexpected {obj!r}")

    data = {"tags": {"b", "a"}, "c": Color.RED}
    assert zaml.load(zaml.dump(data, default=default)) == {"tags": ["a", "b"], "c": {"color": "RED"}}


def test_default_applies_to_keys():
    data = {datetime.date(2026, 11, 19): "release"}
    assert zaml.load(zaml.dump(data, default=lambda d: d.isoformat())) == {"2026-11-19": "release"}


def test_default_key_must_not_become_a_collection():
    with pytest.raises(TypeError, match="mapping keys"):
        zaml.dump({datetime.date(2026, 1, 1): 1}, default=lambda d: [d.year])


def test_default_is_not_called_for_supported_types():
    calls = []
    zaml.dump({"a": [1, 2.5, "s", None, True, (1,)]}, default=calls.append)
    assert calls == []


def test_default_used_by_dump_all():
    assert zaml.load_all(zaml.dump_all([{1, 2}, {3}], default=sorted)) == [[1, 2], [3]]


def test_default_errors_propagate():
    def default(obj):
        raise KeyError("boom")

    with pytest.raises(KeyError, match="boom"):
        zaml.dump({"a": object()}, default=default)


def test_default_that_never_settles():
    with pytest.raises(ValueError, match="nested"):
        zaml.dump(object(), default=lambda o: o)


def test_default_must_be_callable():
    with pytest.raises(TypeError, match="callable"):
        zaml.dump({}, default=42)  # pyright: ignore[reportArgumentType]


class _Mutator:
    """An unsupported value whose `default` empties the container being dumped."""


def test_default_clearing_the_dict_being_dumped():
    data = {"a": _Mutator(), "b": "x" * 100, "c": "y" * 100}
    with pytest.raises(RuntimeError, match="changed size"):
        zaml.dump(data, default=lambda o: data.clear())


def test_default_clearing_the_list_being_dumped():
    data = [_Mutator(), "x" * 100, "y" * 100]
    with pytest.raises(IndexError):
        zaml.dump(data, default=lambda o: data.clear())


def test_default_freeing_strings_already_converted():
    # The strings dumped before `default` runs are freed by it; the output must
    # still contain them intact.
    data = {"first": "z" * 1000, "obj": _Mutator()}

    def default(obj):
        data["first"] = None
        return "replaced"

    text = zaml.dump(data, default=default)
    assert zaml.load(text) == {"first": "z" * 1000, "obj": "replaced"}


# ---------------------------------------------------------------------------
# Repeated mapping keys share one Python string per load

def test_repeated_keys_share_one_string():
    records = zaml.load("- {name: a, id: 1}\n- {name: b, id: 2}\n- {name: c, id: 3}\n")
    first_keys = list(records[0])
    for record in records[1:]:
        assert all(k1 is k2 for k1, k2 in zip(first_keys, record))


def test_many_unique_keys_after_cache_fills():
    # More distinct keys than the cache holds, then repeats of early and late keys.
    data = {f"key{i}": {"x": i} for i in range(10_000)}
    text = zaml.dump(data)
    assert zaml.load(text) == data


def test_long_keys_are_not_cached_but_load():
    long_key = "k" * 100
    assert zaml.load(f"- {{{long_key}: 1}}\n- {{{long_key}: 2}}\n") == [{long_key: 1}, {long_key: 2}]


def test_duplicate_key_error_with_cached_keys():
    with pytest.raises(zaml.YAMLError, match="duplicate"):
        zaml.load("- {a: 1}\n- {a: 1, b: 2, a: 3}\n")


# ---------------------------------------------------------------------------
# Regressions found in review: objects freed or Python code run mid-dump


def _fresh_documents():
    # Every document and string is created here and referenced nowhere else.
    for i in range(50):
        yield {"name": "".join(["document-", str(i), "-", "x" * 2000]), "items": [f"item-{i}"] * 3}


def test_dump_all_generator_documents_are_kept_alive():
    assert zaml.load_all(zaml.dump_all(_fresh_documents())) == list(_fresh_documents())


def test_dump_all_generator_of_bare_strings():
    def strings():
        for i in range(50):
            yield "".join(["string-", str(i), "-", "y" * 2000])

    assert zaml.load_all(zaml.dump_all(strings())) == list(strings())


def test_dump_all_generator_with_default():
    def docs():
        for i in range(20):
            yield {"tags": {f"t{i}-" + "z" * 500}}

    assert zaml.load_all(zaml.dump_all(docs(), default=sorted)) == [
        {"tags": [f"t{i}-" + "z" * 500]} for i in range(20)
    ]


def test_dump_does_not_consult_overridden_class():
    # isinstance() would call this property, which frees the string dumped
    # before it; zaml must check the real type instead.
    data = []

    class Trigger(dict):
        @property
        def __class__(self):  # pyright: ignore[reportIncompatibleMethodOverride]
            data[0] = None
            # Reuse the freed memory, so a dangling pointer reads other bytes.
            self.churn = ["y" * 20020 for _ in range(100)]
            return dict

    first = "".join(["DYNAMIC_STRING_", "x" * 20000])
    data.extend([first, Trigger(a=1)])
    del first
    assert zaml.load(zaml.dump(data)) == ["DYNAMIC_STRING_" + "x" * 20000, {"a": 1}]


def test_dump_ignores_class_property_that_raises():
    class Bad(dict):
        @property
        def __class__(self):  # pyright: ignore[reportIncompatibleMethodOverride]
            raise RuntimeError("must not be called")

    assert zaml.load(zaml.dump([Bad(a=1)])) == [{"a": 1}]


# ---------------------------------------------------------------------------
# Subinterpreters: each interpreter gets its own module state

def test_isolated_subinterpreters():
    interpreters = pytest.importorskip("concurrent.interpreters")  # Python 3.14+
    probe = """
import zaml
assert zaml.load(zaml.dump({"a": [1, 2.5, "x"]})) == {"a": [1, 2.5, "x"]}
try:
    zaml.load("a: [1")
except zaml.YAMLError:
    pass
"""
    interps = [interpreters.create() for _ in range(2)]
    try:
        for interp in interps:
            interp.exec(probe)
        # Each interpreter, and this one, has its own exception class.
        ids = {interp.call(_yaml_error_id) for interp in interps}
        ids.add(_yaml_error_id())
        assert len(ids) == 3
    finally:
        for interp in interps:
            interp.close()


def _yaml_error_id():
    import zaml

    return id(zaml.YAMLError)
