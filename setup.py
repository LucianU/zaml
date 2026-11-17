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


def zig_target():
    """Pin the target where the host default would make a wheel too specific."""
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine().lower(), platform.machine().lower())
    system = platform.system()
    if system == "Darwin":
        deployment = os.environ.get("MACOSX_DEPLOYMENT_TARGET") or sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET")
        if deployment:
            version = str(deployment)
            if "." not in version:
                version += ".0"  # zig needs "15.0", not "15"
            return f"{machine}-macos.{version}"
    if system == "Windows":
        return f"{machine}-windows-msvc"
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
            target = zig_target()
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
