from typing import Any, Literal, Protocol

class YAMLError(ValueError): ...

class _Readable(Protocol):
    def read(self) -> str | bytes: ...

_Schema = Literal["core", "yaml11", "json", "failsafe"]

def load(stream: str | bytes | _Readable, /, *, schema: _Schema = "core") -> Any:
    """Parse the first YAML document in a str, bytes or file object."""

def load_all(stream: str | bytes | _Readable, /, *, schema: _Schema = "core") -> list[Any]:
    """Parse every YAML document in a str, bytes or file object into a list."""
