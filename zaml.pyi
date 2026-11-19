from collections.abc import Iterable
from typing import Any, Literal, Protocol, overload

class YAMLError(ValueError): ...

class _Readable(Protocol):
    def read(self) -> str | bytes: ...

class _Writable(Protocol):
    def write(self, text: str, /) -> object: ...

_Schema = Literal["core", "yaml11", "json", "failsafe"]

def load(stream: str | bytes | _Readable, /, *, schema: _Schema = "core") -> Any:
    """Parse the first YAML document in a str, bytes or file object."""

def load_all(stream: str | bytes | _Readable, /, *, schema: _Schema = "core") -> list[Any]:
    """Parse every YAML document in a str, bytes or file object into a list."""

@overload
def dump(data: Any, /, stream: None = None, *, indent: int = 2, sort_keys: bool = False) -> str: ...
@overload
def dump(data: Any, /, stream: _Writable, *, indent: int = 2, sort_keys: bool = False) -> None: ...
@overload
def dump_all(documents: Iterable[Any], /, stream: None = None, *, indent: int = 2, sort_keys: bool = False) -> str: ...
@overload
def dump_all(documents: Iterable[Any], /, stream: _Writable, *, indent: int = 2, sort_keys: bool = False) -> None: ...
