# OMT Receiver icon

Original artwork: a mint incoming signal entering a display, with separate glass,
frame and signal layers. No third-party symbols, logos, fonts or stock images.

Open **OMTReceiver.icon** in Icon Composer to edit and preview the layered symbol.
It was created and visually checked in Xcode 27.1's Icon Composer. The native
Composer preview adds its own Liquid Glass styling and square system mask.

Apple's [app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
uses Icon Composer for iOS/macOS/watchOS. tvOS uses rectangular image stacks in
Xcode, with system parallax and shine. The .icon document is therefore an editable
design companion, not a tvOS build resource.

The application uses four native tvOS layers, front to back: IncomingSignal,
DisplayFrame, DisplayGlass and an opaque Background. The symbol occupies the
central 70% of the icon height to leave room for focus motion. Rounded icon
corners, shadows and shine are supplied by tvOS rather than baked into the PNGs.
The rectangular background is retained separately in Source/Background.svg; the
Composer preview uses an automatic dark-teal gradient for its square canvas.

Checked-in assets cover 400×240 @1x/@2x, the 1280×768 App Store stack, and both
standard and wide Top Shelf images @1x/@2x. The app builds without design tools.
To regenerate after changing the SVGs in the .icon document, install librsvg's
rsvg-convert and run:

```sh
python3 scripts/generate_icons.py
```

Source/ keeps the original vector artwork. The .icon/Assets copies are the
foreground master used by the tvOS generator. tvOS-preview.png and
tvOS-small-preview.png are flat artwork previews; they do not simulate parallax.
