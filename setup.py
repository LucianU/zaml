"""Build the zaml extension with `zig build`.

Zig itself comes from the `ziglang` PyPI package (a build requirement), so no
separate Zig installation is needed. Set ZIG to use a different zig binary.
"""

import os
import platform
import shlex
import shutil
import sys
import sysconfig
import tempfile
from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

ROOT = Path(__file__).parent.resolve()
LIMITED_API = "cp310"  # matches Py_LIMITED_API in src/python.h


def zig_command():
    if "ZIG" in os.environ:
        return shlex.split(os.environ["ZIG"])
    return [sys.executable, "-m", "ziglang"]


ZIG_ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "amd64": "x86_64", "x86_64": "x86_64", "win32": "x86"}


def zig_target(python_platform, host_machine, deployment_target=None):
    """Return the zig target for the Python being built for, or None for the host default.

    python_platform is sysconfig.get_platform(), such as "win-amd64", "win32" or
    "macosx-11.0-arm64". It describes the target Python, not the build machine,
    and follows _PYTHON_HOST_PLATFORM when cibuildwheel cross-compiles.
    """
    host_arch = ZIG_ARCH.get(host_machine.lower(), host_machine.lower())
    if python_platform == "win32":
        return "x86-windows-msvc"
    if python_platform.startswith("win-"):
        arch = python_platform.removeprefix("win-")
        return f"{ZIG_ARCH.get(arch, arch)}-windows-msvc"
    if python_platform.startswith("macosx-"):
        _, version, arch = python_platform.split("-", 2)
        # A universal2 Python runs natively here, so build for this machine.
        arch = ZIG_ARCH.get(arch, host_arch)
        version = deployment_target or version
        if "." not in version:
            version += ".0"  # zig needs "15.0", not "15"
        return f"{arch}-macos.{version}"
    return None


class ZigBuildExt(build_ext):
    def build_extension(self, ext):
        output = Path(self.get_ext_fullpath(ext.name))
        output.parent.mkdir(parents=True, exist_ok=True)

        windows = platform.system() == "Windows"
        with tempfile.TemporaryDirectory() as prefix:
            command = [
                *zig_command(),
                "build",
                "--build-file",
                str(ROOT / "build.zig"),
                "--prefix",
                prefix,
                "-Doptimize=ReleaseFast",
                f"-Dpython-include={sysconfig.get_paths()['include']}",
            ]
            target = zig_target(sysconfig.get_platform(), platform.machine(), os.environ.get("MACOSX_DEPLOYMENT_TARGET"))
            if target:
                command.append(f"-Dtarget={target}")
            if windows:
                command.append(f"-Dpython-libdir={Path(sysconfig.get_config_var('installed_base')) / 'libs'}")
            self.spawn(command)

            built = {
                "Windows": Path(prefix, "bin", "zaml.dll"),
                "Darwin": Path(prefix, "lib", "libzaml.dylib"),
            }.get(platform.system(), Path(prefix, "lib", "libzaml.so"))
            shutil.copyfile(built, output)


setup(
    ext_modules=[Extension("zaml", sources=["src/zaml.zig"], py_limited_api=True)],
    cmdclass={"build_ext": ZigBuildExt},
    options={"bdist_wheel": {"py_limited_api": LIMITED_API}},
)
