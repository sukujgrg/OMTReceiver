using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using libomtnet;

internal static partial class Program
{
    private static int RunSenderChild(string[] args, string report)
    {
        OMTSettings.GetInstance().SetString("DiscoveryServer", Argument(args, "--discovery"));
        Source? source = null;
        string? errorText = null;
        try
        {
            source = new Source(int.Parse(Argument(args, "--port")), Argument(args, "--name"));
            Console.WriteLine("OMT_PROBE_READY " + JsonSerializer.Serialize(new { source.Port, source.Boundary }));
            Console.Out.Flush();
            while (Console.ReadLine() is string command && command != "STOP") source.Check();
        }
        catch (Exception error) { errorText = error.ToString(); }
        finally
        {
            try { source?.Dispose(); } catch (Exception error) { errorText += "\nShutdown: " + error; }
            OMTDiscovery.GetInstance().Dispose();
            File.WriteAllText(report, JsonSerializer.Serialize(new
            {
                Error = errorText, ProcessID = Environment.ProcessId,
                OmittedCalls = source?.OmittedCalls ?? 0, Calls = source?.Calls ?? new List<Call>()
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        return errorText == null ? 0 : 1;
    }

    private sealed class ChildSender : IDisposable
    {
        private readonly Process process;
        private readonly string reportPath;
        private readonly string logPath;
        private readonly List<string> startup = new();
        private readonly Task<string> stderr;
        private bool stopped;
        private int? exitCode;
        public long Boundary { get; private set; }
        public int PID => process.Id;
        public ChildSender(string codec, string storage, int port, string name, int discoveryPort)
        {
            Directory.CreateDirectory(storage);
            reportPath = Path.Combine(storage, "source.json");
            logPath = Path.Combine(storage, "child-console.log");
            var start = new ProcessStartInfo(Environment.ProcessPath!)
            {
                RedirectStandardInput = true, RedirectStandardOutput = true,
                RedirectStandardError = true, UseShellExecute = false
            };
            start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
            foreach (string argument in new[] { "--sender-child", "--codec", codec, "--storage", storage,
                "--report", reportPath, "--port", port.ToString(), "--name", name,
                "--discovery", "omt://127.0.0.1:" + discoveryPort }) start.ArgumentList.Add(argument);
            process = Process.Start(start)!;
            stderr = process.StandardError.ReadToEndAsync();
            try
            {
                var clock = Stopwatch.StartNew();
                while (clock.ElapsedMilliseconds < 5000)
                {
                    string? line = process.StandardOutput.ReadLineAsync()
                        .WaitAsync(TimeSpan.FromMilliseconds(Math.Max(1, 5000 - clock.ElapsedMilliseconds)))
                        .GetAwaiter().GetResult();
                    if (line == null) throw new InvalidOperationException("Sender child exited before ready: " + string.Join("\n", startup));
                    startup.Add(line);
                    if (!line.StartsWith("OMT_PROBE_READY ", StringComparison.Ordinal)) continue;
                    using var ready = JsonDocument.Parse(line[16..]);
                    Require(ready.RootElement.GetProperty("Port").GetInt32() == port, "Child bound another listener");
                    Boundary = ready.RootElement.GetProperty("Boundary").GetInt64();
                    return;
                }
                throw new TimeoutException("Sender child readiness deadline");
            }
            catch { Dispose(); throw; }
        }
        public JsonElement StopAndReadReport()
        {
            Dispose();
            Require(exitCode == 0, "Sender child failed; see " + logPath);
            using var document = JsonDocument.Parse(File.ReadAllText(reportPath));
            Require(document.RootElement.GetProperty("Error").ValueKind == JsonValueKind.Null, "Sender child reported an error");
            Require(document.RootElement.GetProperty("OmittedCalls").GetInt32() == 0, "Sender trace overflow");
            return document.RootElement.Clone();
        }
        public void Dispose()
        {
            if (stopped) return;
            stopped = true;
            if (!process.HasExited)
            {
                try { process.StandardInput.WriteLine("STOP"); process.StandardInput.Flush(); }
                catch (IOException) { }
                if (!process.WaitForExit(5000))
                {
                    process.Kill(entireProcessTree: true);
                    Require(process.WaitForExit(5000), "Sender child did not retire");
                }
            }
            string output = string.Join("\n", startup) + "\n" + process.StandardOutput.ReadToEnd();
            File.WriteAllText(logPath, output + "\nSTDERR:\n" + stderr.GetAwaiter().GetResult());
            exitCode = process.ExitCode;
            process.Dispose();
        }
    }

    private static int RunSenderProcesses(string codec, string storage, string report, int rounds, int discoveryPort)
    {
        int port = FreePort();
        string endpoint = "omt://127.0.0.1:" + port;
        string name = "Public process video " + Guid.NewGuid().ToString("N");
        OMTReceive? receiver = null;
        ChildSender? child = null;
        var cycles = new List<object>();
        var sources = new List<JsonElement>();
        bool passed = true;
        string? errorText = null;
        var total = Stopwatch.StartNew();
        try
        {
            long lastTimecode = -1;
            for (int cycle = 0; cycle < rounds; cycle++)
            {
                if (child != null) sources.Add(child.StopAndReadReport());
                child = null;
                child = new ChildSender(codec, Path.Combine(storage, "sender-" + cycle), port, name, discoveryPort);
                receiver ??= new OMTReceive(endpoint, OMTFrameType.Video, OMTPreferredVideoFormat.BGRA, OMTReceiveFlags.None);
                var clock = Stopwatch.StartNew();
                int frames = 0, pending = 0, stale = 0;
                double? firstFreshMilliseconds = null;
                var observations = new List<object>();
                while (clock.ElapsedMilliseconds < 8000 && frames < 3)
                {
                    OMTMediaFrame frame = default;
                    bool received = receiver.Receive(OMTFrameType.Video, 100, ref frame);
                    if (observations.Count < 256) observations.Add(new
                    {
                        ElapsedMs = clock.Elapsed.TotalMilliseconds, Received = received,
                        ReceiverConnected = receiver.IsConnected(), Timestamp = received ? frame.Timestamp : (long?)null
                    });
                    if (!received) { pending++; continue; }
                    Require(frame.Width == 1920 && frame.Height == 1080 && frame.Codec == (int)OMTCodec.BGRA &&
                        frame.Data != IntPtr.Zero && frame.Stride >= 7680 && frame.DataLength >= frame.Stride * frame.Height,
                        "Invalid decoded 1080p BGRA frame");
                    if (frame.Timestamp < child.Boundary) { stale++; continue; }
                    Require(frame.Timestamp > lastTimecode, "Fresh process video timestamp repeated or regressed");
                    lastTimecode = frame.Timestamp;
                    firstFreshMilliseconds ??= clock.Elapsed.TotalMilliseconds;
                    frames++;
                }
                bool withinTarget = frames >= 3 && firstFreshMilliseconds is double firstFresh && firstFresh <= 4000;
                cycles.Add(new
                {
                    Cycle = cycle, SenderPID = child.PID, Frames = frames, PendingCalls = pending, StaleFrames = stale,
                    FirstFreshMs = firstFreshMilliseconds, ElapsedMs = clock.Elapsed.TotalMilliseconds,
                    PassedFourSecondTarget = withinTarget, ReceiverConnected = receiver.IsConnected(), Observations = observations
                });
                Console.WriteLine($"process cycle={cycle} fresh={frames} firstMs={firstFreshMilliseconds} pending={pending} targetPassed={withinTarget}");
                if (!withinTarget) { passed = false; break; }
            }
        }
        catch (Exception error) { passed = false; errorText = error.ToString(); }
        finally
        {
            try { receiver?.Dispose(); } catch (Exception error) { passed = false; errorText += "\nReceiver shutdown: " + error; }
            try { if (child != null) sources.Add(child.StopAndReadReport()); }
            catch (Exception error) { passed = false; errorText += "\nSender shutdown: " + error; }
            File.WriteAllText(report, JsonSerializer.Serialize(new
            {
                Passed = passed, Error = errorText, Endpoint = endpoint, Rounds = rounds,
                SDKAssembly = typeof(OMTSend).Assembly.GetName().Version?.ToString(),
                Scope = "Public managed APIs; persistent video-only receiver, same direct URL, new sender subprocess per cycle; real1080p UYVY/VMX decodedBGRA, no metadata/audio. Four-second first-frame target, eight-second diagnostic ceiling; absolute monotonic timestamps.",
                DurationSeconds = total.Elapsed.TotalSeconds, Cycles = cycles, SenderReports = sources
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        return passed ? 0 : 1;
    }
}
