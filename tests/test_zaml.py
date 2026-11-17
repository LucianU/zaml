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
        zaml.load("a: 1", schema="yaml13")


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
        zaml.load(Reader())


def test_yaml_error_is_value_error():
    assert issubclass(zaml.YAMLError, ValueError)


def test_wrong_type_raises():
    with pytest.raises(TypeError):
        zaml.load(42)


def test_matches_pyyaml_on_large_mapping():
    data = {f"a{i}": f"b{i + 1}" for i in range(10_000)}
    text = pyyaml.dump(data, Dumper=pyyaml.SafeDumper)
    assert zaml.load(text) == pyyaml.safe_load(text) == data
