# Grim

A Nim-based domain-specific language for lattice field theory built on
[Grid](https://github.com/paboyle/Grid).

---

## License

The Grim source code is released under the **MIT License** — see
[LICENSE](LICENSE) for the full text.

### Grid dependency (GPLv2)

Grim generates C++ that `#include`s headers from and links against
[Grid](https://github.com/paboyle/Grid), which is licensed under the
**GNU General Public License v2.0**.

**This repository does not contain any Grid source code.** Grid is
fetched and built separately (e.g. via `bootstrap.py`).

Because compiled Grim binaries link against Grid, any **distribution of
those binaries** is subject to the terms of the GPLv2. In practice this
means:

- You may freely use, modify, and distribute the Grim *source code*
  under the MIT License.
- If you distribute a *compiled binary* that links Grid, that binary
  (as a combined work) must comply with the GPLv2 — you must make the
  complete corresponding source available under GPLv2-compatible terms.
- Private/internal use of compiled binaries does not trigger any
  distribution obligations.

MIT is GPLv2-compatible, so the combined work can lawfully be
distributed under GPLv2.