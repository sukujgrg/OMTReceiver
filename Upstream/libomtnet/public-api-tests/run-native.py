#!/usr/bin/env python3
"""Compile a public C-API probe and run one verified, unmodified native SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from run import bounded


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("library", "codec", "header", "source-manifest", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--fresh-frames", type=int, choices=(1, 3), default=3)
    parser.add_argument("--port", type=int, default=0, help="Optional fixed listener for an isolated socket trace; zero chooses a free port")
    parser.add_argument("--terminal-alpha", action="store_true")
    parser.add_argument("--terminal-same", action="store_true")
    parser.add_argument("--immediate-exit", action="store_true")
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()
    if args.terminal_alpha and args.terminal_same:
        parser.error("Choose one terminal picture format")
    if args.port != 0 and not 1024 <= args.port <= 65535:
        parser.error("port must be zero or 1024–65535")
    library, codec, header, source_manifest, output = (
        getattr(args, name).resolve()
        for name in ("library", "codec", "header", "source_manifest", "output"))
    source_build = json.loads(source_manifest.read_text())
    if source_build["sha256"] != digest(library) or not source_build["sourceBytesUnmodifiedAfterBuild"]:
        raise RuntimeError("Native library must match its unmodified-source build manifest")
    if not 1 <= args.rounds <= 32:
        parser.error("rounds must be 1–32")
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).with_name("native-direct-restart.c").resolve()
    binary = output / "native-direct-restart"
    build = ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I", str(header.parent), str(source), "-o", str(binary)]
    run = [str(binary), str(library), str(codec), str(output / "run"),
           str(args.rounds), str(args.fresh_frames)]
    environment = os.environ.copy()
    if args.port:
        environment["OMT_PROBE_PORT"] = str(args.port)
    else:
        environment.pop("OMT_PROBE_PORT", None)
    if args.terminal_alpha:
        environment["OMT_PROBE_TERMINAL_ALPHA"] = "1"
    else:
        environment.pop("OMT_PROBE_TERMINAL_ALPHA", None)
    for enabled, key in ((args.terminal_same, "OMT_PROBE_TERMINAL_SAME"),
                         (args.immediate_exit, "OMT_PROBE_IMMEDIATE_EXIT")):
        if enabled:
            environment[key] = "1"
        else:
            environment.pop(key, None)
    manifest = dict(sourceBuild=source_build["commits"], librarySHA256=digest(library),
                    codecSHA256=digest(codec), headerSHA256=digest(header),
                    harnessSHA256=digest(source), build=build, run=run,
                    terminalAlpha=args.terminal_alpha, terminalSame=args.terminal_same,
                    immediateChildExit=args.immediate_exit, requiredFreshFrames=args.fresh_frames,
                    requestedPort=args.port,
                    scope="Public C API with real native runtime, sender subprocess replacement and one persistent direct-video receiver.")
    path = output / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    code = bounded(build, source.parent, environment, output / "build.log", 60)
    manifest["buildExitCode"] = code
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    if code == 0 and not args.compile_only:
        code = bounded(run, source.parent, environment, output / "run.log", 180)
        manifest["runExitCode"] = code
        path.write_text(json.dumps(manifest, indent=2) + "\n")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
