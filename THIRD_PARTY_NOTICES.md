# Third-party notices

Original application source and artwork are MIT-licensed; see LICENSE. The app
bundles the complete notices in Resources/ThirdPartyNotices.txt and displays
them under About → Third-Party Licences.

## Official VMX codec

Source: https://github.com/openmediatransport/libvmx

Vendored revision: `31724bb96530325a989bc157c8e07538d6f1c4db`

Upstream revision date: 2026-10-20.

The codec's source and original license are retained in `Vendor/libvmx/`.
It is distributed under the MIT license. The bundled `sse2neon.h` also retains
its own upstream license notices. Local modifications are documented separately
in `Vendor/libvmx/PATCHES.md`.

The downloaded upstream source archive had SHA-256:
`b5b10a4fd244ff2aa757fd40342c90d14014b966e82afa3471c527768182c220`.

## OMT protocol reference

Source: https://github.com/openmediatransport/libomtnet

Reference revision: `7d29031ff3f355ffa1f0cd08ee24d02e258445dd`

The Swift transport is an independent implementation of the published OMT 1.0
wire protocol, checked against the official implementation. Official SDK binaries
are used only by the optional Mac interoperability test sender; they are not
embedded in the tvOS application.

Open Media Transport and its associated marks belong to their respective owners.
This prototype is an independent receiver, not an official OMT product.
