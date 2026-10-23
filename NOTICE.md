# Protocol reference

The RGB frame and device protocol constants were verified against Polyfish0's public **Unofficial Ado Light Stick Controller**:

- Repository: https://github.com/Polyfish0/abo-light-stick-app
- Reference file: `app/src/main/java/de/polyfish0/adolightstick/LightStickCommandBuilder.kt`
- Reference blob: `c11638d25ecf83a6d1eeef6334b42898a6b03ae8`
- Upstream license: GNU General Public License version 3.0, https://github.com/Polyfish0/abo-light-stick-app/blob/master/LICENSE

`PenlightProtocol.swift` independently implements that protocol using macOS CommonCrypto. No official application was unpacked or decompiled for this work. The protocol's public fixed key is a device protocol constant, not a user credential.

This project is distributed under GPL-3.0 (see LICENSE). It is an unofficial personal tool and is not affiliated with Ado or Ruifan Japan.
