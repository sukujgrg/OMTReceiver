#!/usr/bin/env python3
"""Build and run against a verified pristine SDK; never patch or publish it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def bounded(command, directory, environment, log, seconds):
    process = subprocess.Popen(command, cwd=directory, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        log.write_text(output + "\nTEST PROCESS GROUP DEADLINE REACHED\n")
        raise
    log.write_text(output)
    print(output, end="", flush=True)
    return process.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("upstream", "commit", "codec", "dotnet", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--audio-metadata-probe", action="store_true")
    parser.add_argument("--direct-video-restart-probe", action="store_true")
    parser.add_argument("--sender-processes", action="store_true")
    args = parser.parse_args()
    if args.audio_metadata_probe and args.direct_video_restart_probe:
        parser.error("Choose one separate probe")
    if args.sender_processes and not args.direct_video_restart_probe:
        parser.error("--sender-processes requires --direct-video-restart-probe")
    upstream, codec, dotnet, output = (Path(getattr(args, name)).resolve()
                                      for name in ("upstream", "codec", "dotnet", "output"))
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain=v1", "--untracked-files=all"],
                                    cwd=upstream, text=True)
    if commit != args.commit or dirty:
        raise RuntimeError("SDK must be pristine at the explicitly requested commit")
    if not 1 <= args.rounds <= 32:
        raise ValueError("rounds must be between 1 and 32")
    output.mkdir(parents=True, exist_ok=False)
    project = Path(__file__).with_name("PublicApiLifecycle.csproj").resolve()
    if args.direct_video_restart_probe:
        project = project.parent / "direct-video-restart/DirectVideoRestart.csproj"
    environment = os.environ.copy()
    environment.update(DOTNET_ROOT=str(dotnet.parent), DOTNET_CLI_TELEMETRY_OPTOUT="1",
                       DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
    environment.setdefault("DOTNET_CLI_HOME", str(output / "cli-home"))
    environment.setdefault("NUGET_PACKAGES", str(output / "nuget"))
    build = [str(dotnet), "build", str(project), "-c", "Release", "--artifacts-path",
             str(output / "artifacts"), "-p:OMTUpstreamRoot=" + str(upstream),
             "-p:NuGetAudit=false", "-p:UseSharedCompilation=false", "-nodeReuse:false", "-m:1"]
    run = [str(dotnet), str(output / f"artifacts/bin/{project.stem}/release/{project.stem}.dll"),
           "--codec", str(codec), "--storage", str(output / "storage"),
           "--report", str(output / "report.json"), "--rounds", str(args.rounds)]
    if args.audio_metadata_probe:
        run.append("--audio-metadata-probe")
    if args.sender_processes:
        run.append("--sender-processes")
    manifest = dict(commit=commit, pristine=True, upstream=str(upstream), build=build, run=run,
                    codecSHA256=hashlib.sha256(codec.read_bytes()).hexdigest(),
                    harnessSHA256=hashlib.sha256(project.with_name("Program.cs").read_bytes()).hexdigest(),
                    harnessSourceSHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in sorted(project.parent.glob("*.cs"))},
                    sourceSHA256={str(p.relative_to(upstream)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sorted((upstream / "src").rglob("*.cs"))},
                    startedUnix=time.time())
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    code = bounded(build, project.parent, environment, output / "build.log", 120)
    manifest["buildExitCode"] = code
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    if code == 0:
        code = bounded(run, project.parent, environment, output / "run.log", 180)
        manifest["runExitCode"] = code
        manifest["finishedUnix"] = time.time()
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
