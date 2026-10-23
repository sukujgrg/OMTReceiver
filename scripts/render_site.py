#!/usr/bin/env python3
"""Generate the public GitHub Pages support site without app code or captures."""
from pathlib import Path
from html import escape
import shutil
ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT/'docs'
SITE.mkdir(exist_ok=True)
(SITE/'assets').mkdir(exist_ok=True)
shutil.copyfile(ROOT/'Design/AppIcon/tvOS-preview.png', SITE/'assets/icon.png')
(SITE/'.nojekyll').write_text('')
def page(title, content):
    return '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark light"><title>'+escape(title)+' — OMT Receiver</title><link rel="stylesheet" href="style.css"></head><body><header><a class="brand" href="./">OMT Receiver</a><nav aria-label="Main"><a href="support.html">Support</a><a href="privacy.html">Privacy</a><a href="https://github.com/sukujgrg/OMTReceiver">Source</a></nav></header><main>'+content+'</main><footer>Independent Open Media Transport receiver · <a href="https://github.com/sukujgrg/OMTReceiver/blob/main/LICENSE">MIT licence</a></footer></body></html>\n'
def lines_html(lines):
    return '<br>'.join('<a href="'+escape(line, quote=True)+'">'+escape(line)+'</a>'
                       if line.startswith('https://') and ' ' not in line else escape(line)
                       for line in lines)

def paragraphs(text, heading='h2'):
    parts = text.strip().split('\n\n')
    title, *subtitle = parts[0].splitlines()
    content = '<'+heading+'>'+escape(title)+'</'+heading+'>'
    if subtitle:
        content += '<p class="status">'+lines_html(subtitle)+'</p>'
    section_titles = {'Network use', 'Data on your Apple TV', 'Retention and control',
                      'Contact', 'Policy URL', 'Support'}
    for part in parts[1:]:
        lines = part.splitlines()
        if lines[0] in section_titles:
            content += '<h2>'+escape(lines.pop(0))+'</h2>'
        content += '<p>'+lines_html(lines)+'</p>'
    return content

privacy=(ROOT/'OMTReceiver/Resources/PrivacyPolicy.txt').read_text()
help_text=(ROOT/'OMTReceiver/Resources/GettingStarted.txt').read_text()
(SITE/'privacy.html').write_text(page('Privacy Policy', paragraphs(privacy, heading='h1')))
(SITE/'support.html').write_text(page('Support', '<h1>Support</h1><p>For help or a bug report, use the <a href="https://github.com/sukujgrg/OMTReceiver/issues">public issue tracker</a>. Do not include credentials, private network addresses or recordings.</p>'+paragraphs(help_text)))
(SITE/'index.html').write_text(page('Apple TV video receiver', '<section class="hero"><div><p class="eyebrow">tvOS · Independent · Open source</p><h1>Your OMT source.<br>Your Apple TV.</h1><p>Receive Open Media Transport video and audio full screen on Apple TV. Choose a network source and let your display do the rest.</p><p class="status">Pre-release — App Store preparation is in progress.</p><p><a class="button" href="support.html">Get started</a> <a href="https://github.com/sukujgrg/OMTReceiver">View the source</a></p></div><img src="assets/icon.png" width="1280" height="768" alt="A mint signal arrow entering a display"></section><section class="features"><article><h2>Connect directly</h2><p>Discover OMT sources with Bonjour or enter the source address. A separate compatible sender is required.</p></article><article><h2>Full screen, with audio</h2><p>8-bit SDR video through 1080p60, automatic interlaced conversion and FPA1 audio. Ethernet is recommended. Sustained 60 fps qualification remains in progress.</p></article><article><h2>Keep control</h2><p>Siri Remote controls for source selection, mute, requested quality and reconnect. No account, ads or tracking.</p></article></section><p>Requires tvOS 17 or later. One source at a time; 4K input, HDR and multiview are not supported. Open Media Transport and associated marks belong to their owners.</p>'))
(SITE/'style.css').write_text(""":root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#e9f5f7;background:#0c1d2c;line-height:1.6}*{box-sizing:border-box}body{margin:0}a{color:#79f3d0;text-underline-offset:.2em}a:focus-visible{outline:3px solid #79f3d0;outline-offset:6px;border-radius:4px}header,main,footer{max-width:1120px;margin:auto;padding:28px}header{display:flex;justify-content:space-between;gap:24px;align-items:center;border-bottom:1px solid #29414b}.brand{color:#fff;font-weight:700;text-decoration:none;font-size:1.2rem}nav{display:flex;gap:24px}h1,h2{line-height:1.15;letter-spacing:-.03em}h1{font-size:clamp(2.2rem,5vw,3.9rem);margin:.4em 0}h2{font-size:1.4rem}.hero{display:grid;grid-template-columns:1fr 1fr;gap:48px;align-items:center;padding:40px 0 64px}.hero img{width:100%;height:auto;border-radius:24px;border:1px solid #29414b}.eyebrow{color:#79f3d0;font-weight:600;letter-spacing:.08em;text-transform:uppercase;font-size:.85rem}.status{color:#b5ccd2;font-size:.95rem}.button{display:inline-block;padding:10px 18px;background:#79f3d0;border-radius:10px;color:#0c1d2c;font-weight:650;text-decoration:none;margin-right:14px}.features{display:grid;grid-template-columns:repeat(3,1fr);gap:32px;margin-bottom:44px}main>p{max-width:80ch;overflow-wrap:anywhere}footer{border-top:1px solid #29414b;color:#a4bec7;font-size:.9rem}@media(max-width:760px){header{align-items:flex-start;flex-direction:column}.hero,.features{grid-template-columns:1fr}.hero{gap:28px;padding:24px 0 40px}header,main,footer{padding:22px}nav{gap:20px}}
""")
print('Generated public support/privacy pages from the same text bundled in the app.')
