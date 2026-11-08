# Third-party notices

Worker dependencies and versions are pinned in [pyproject.toml](pyproject.toml) and
[uv.lock](uv.lock). Runtime and development/build dependencies are distinguished
when [the collector](../script/generate_notices.py) runs inside the frozen environment.

The collector copies complete distribution license/copyright/notice files and the
CPython license into ignored build/third-party, with README.md and inventory.json.
The qualified managed Python build has pinned upstream component notices under
[runtime license provenance](../licenses/python-runtime/README.md); development
Homebrew builds also collect notices from the actual external dylib packages.
The release worker bundles this directory as ThirdPartyLicenses. Additional
build-package notices are supplied conservatively rather than described as runtime
requirements. Missing runtime license text fails packaging.

PyInstaller has a distribution exception; it does not select the project's license.
See its [official license](https://pyinstaller.org/en/stable/license.html). Required
terms of the actual bundled Python/dependency/native components still apply. The
generated inventory is a distribution aid, not a completed legal compatibility audit.
