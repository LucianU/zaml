"""Fast YAML loading and dumping for Python, written in Zig."""

from zaml._zaml import YAMLError, dump, dump_all, load, load_all

__all__ = ["YAMLError", "dump", "dump_all", "load", "load_all"]
