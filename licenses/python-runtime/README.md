# Python runtime license provenance

These unchanged license texts come from the pinned upstream Python build revision recorded in manifest.json. The inventory is conservative across upstream components/platforms; the presence of a notice does not claim that its component is included in the macOS package.

The arm64 CPython 3.13.3 archive SHA-256 identifies the selected 20250529 build and matches its upstream `.sha256` release asset. The library hash describes the unchanged archive member, before installation tools rewrite its Mach-O install name. `script/prepare_release_runtime.py` verifies the archive, safely extracts it under ignored `build/release-runtime`, and checks extracted source/native files against the archive (excluding interpreter-regenerated `.pyc` caches) before returning its interpreter. Formal builds select that exact interpreter and disable automatic Python downloads; they do not use a path-dependent uv-managed library hash. All 20 component notices were compared byte-for-byte with the pinned upstream revision on 2026-11-08. Different builds need a new provenance/license review.

Sources: [upstream build](https://github.com/astral-sh/python-build-standalone/tree/cddb9c19fcbb656b5cda420dcd6c3bf196e53beb), [licensing documentation](https://github.com/astral-sh/python-build-standalone/blob/cddb9c19fcbb656b5cda420dcd6c3bf196e53beb/docs/running.rst#licensing).
