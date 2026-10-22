#!/usr/bin/env python3
"""Render checked-in tvOS parallax assets from the editable Icon Composer artwork.

Requires rsvg-convert only when regenerating artwork, never to build the app.
Composer's square .icon file is a design companion: tvOS uses native rectangular
image stacks, with its own system shine/parallax instead of baked Liquid Glass.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parent.parent
DESIGN = PROJECT / 'Design/AppIcon'
ROOT = PROJECT / 'OMTReceiver/Assets.xcassets/AppIcon.brandassets'
MASTER = DESIGN / 'OMTReceiver.icon/Assets'
INFO = {'author': 'xcode', 'version': 1}
LAYER_ORDER = ['IncomingSignal', 'DisplayFrame', 'DisplayGlass', 'Background']


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def shapes(name):
    source = MASTER / (name + '.svg')
    if name == 'Background':
        source = DESIGN / 'Source/Background.svg'
    root = ET.parse(source).getroot()
    return ''.join(ET.tostring(child, encoding='unicode') for child in root)


def document(width, height, names):
    # Keep the entire symbol in the central 70% of height for focus parallax.
    scale = height * 0.70 / 553
    tx, ty = width / 2 - 512 * scale, height / 2 - 493.5 * scale
    body = []
    if 'Background' in names:
        body.append(f'<g transform="scale({width/1024},{height/1024})">{shapes("Background")}</g>')
    for name in ['DisplayGlass', 'DisplayFrame', 'IncomingSignal']:
        if name in names:
            body.append(f'<g transform="translate({tx},{ty}) scale({scale})">{shapes(name)}</g>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">' + ''.join(body) + '</svg>'


def render(path, width, height, names, directory):
    source = Path(directory) / 'render.svg'
    source.write_text(document(width, height, names))
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([CONVERTER, '--format=png', '--output', str(path), str(source)], check=True)


CONVERTER = shutil.which('rsvg-convert')
if CONVERTER is None:
    raise SystemExit('Install librsvg (rsvg-convert) to regenerate artwork; checked-in images need no extra tools to build.')
assets = []
with tempfile.TemporaryDirectory(prefix='omt-icon-') as directory:
    for name, width, height, scales in [('Small', 400, 240, [1, 2]), ('Large', 1280, 768, [1])]:
        stack = ROOT / f'{name}.imagestack'
        layers = []
        for layer in LAYER_ORDER:
            filename = f'{layer}.imagestacklayer'
            layers.append({'filename': filename})
            image_set = stack / filename / 'Content.imageset'
            images = []
            for scale in scales:
                png = f'{layer}@{scale}x.png'
                render(image_set / png, width * scale, height * scale, [layer], directory)
                images.append({'idiom': 'tv', 'scale': f'{scale}x', 'filename': png})
            write_json(image_set / 'Contents.json', {'info': INFO, 'images': images})
            write_json(stack / filename / 'Contents.json', {'info': INFO})
        write_json(stack / 'Contents.json', {'info': INFO, 'layers': layers})
        # Remove only the superseded prototype foreground owned by this generator.
        old = stack / 'Foreground.imagestacklayer'
        if old.exists():
            shutil.rmtree(old)
        assets.append({'size': f'{width}x{height}', 'idiom': 'tv', 'filename': stack.name, 'role': 'primary-app-icon'})
    for name, width, role in [('TopShelf', 1920, 'top-shelf-image'), ('TopShelfWide', 2320, 'top-shelf-image-wide')]:
        image_set = ROOT / f'{name}.imageset'
        images = []
        for scale in [1, 2]:
            png = f'{name}@{scale}x.png'
            render(image_set / png, width * scale, 720 * scale, LAYER_ORDER, directory)
            images.append({'idiom': 'tv', 'scale': f'{scale}x', 'filename': png})
        write_json(image_set / 'Contents.json', {'info': INFO, 'images': images})
        assets.append({'size': f'{width}x720', 'idiom': 'tv', 'filename': image_set.name, 'role': role})
    render(DESIGN / 'tvOS-preview.png', 1280, 768, LAYER_ORDER, directory)
    render(DESIGN / 'tvOS-small-preview.png', 400, 240, LAYER_ORDER, directory)
write_json(ROOT / 'Contents.json', {'info': INFO, 'assets': assets})
print('Generated four-layer tvOS Home Screen, App Store and Top Shelf artwork.')
