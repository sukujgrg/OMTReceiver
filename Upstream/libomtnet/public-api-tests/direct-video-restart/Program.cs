using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using libomtnet;

// A separate public-API case matching the native probe's video-only, persistent
// direct URL. Four seconds remains the recovery target; eight seconds only
// diagnoses a late recovery and cannot turn that failure into a pass.
internal static partial class Program
{
    private static long Now => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
    private static int FreePort()
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        socket.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        return ((IPEndPoint)socket.LocalEndPoint!).Port;
    }
    private static string Argument(string[] args, string name, string? fallback = null)
    {
        int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback ?? throw new ArgumentException(name);
    }
    private sealed record Call(long Started, long Finished, int Epoch, int Returned, int Connections);
    private sealed class Source : IDisposable
    {
        private readonly object gate = new();
        private readonly string name;
        private readonly CancellationTokenSource stop = new();
        private readonly Thread worker;
        private OMTSend sender;
        private Exception? failure;
        private long boundary = Now;
        private int epoch = 1;
        public readonly int Port;
        public readonly List<Call> Calls = new();
        public int OmittedCalls { get; private set; }
        public long Boundary { get { lock (gate) return boundary; } }
        public int Connections { get { lock (gate) return sender.Connections; } }
        public (long VideoDrops, long AudioDrops) Drops
        {
            get { lock (gate) return (sender.GetVideoStatistics().FramesDropped, sender.GetAudioStatistics().FramesDropped); }
        }
        public Source(int? port = null, string? sourceName = null)
        {
            name = sourceName ?? "Public direct video " + Guid.NewGuid().ToString("N");
            Port = port ?? FreePort();
            OMTSettings.GetInstance().SetInteger("NetworkPortStart", Port);
            OMTSettings.GetInstance().SetInteger("NetworkPortEnd", Port);
            sender = new OMTSend(name, OMTQuality.Medium);
            Require(sender.Port == Port, "Initial listener differs from fixed direct URL");
            worker = new Thread(Produce) { IsBackground = true };
            worker.Start();
        }
        public void Restart()
        {
            lock (gate)
            {
                sender.Dispose();
                sender = new OMTSend(name, OMTQuality.Medium);
                Require(sender.Port == Port, "Replacement listener differs from fixed direct URL");
                epoch++; boundary = Now;
            }
        }
        public void Check()
        {
            if (Volatile.Read(ref failure) is Exception error) throw new InvalidOperationException("Sender worker failed", error);
        }
        private void Produce()
        {
            const int width = 1920, height = 1080;
            byte[] picture = new byte[width * height * 2];
            for (int i = 0; i < picture.Length; i += 4)
            {
                picture[i] = 110; picture[i + 1] = (byte)(48 + i / 4 % 150);
                picture[i + 2] = 140; picture[i + 3] = (byte)(48 + i / 8 % 150);
            }
            var pin = GCHandle.Alloc(picture, GCHandleType.Pinned);
            long next = Now;
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    if (Now < next) { Thread.Sleep(1); continue; }
                    lock (gate)
                    {
                        long started = Now;
                        var frame = new OMTMediaFrame
                        {
                            Type = OMTFrameType.Video, Codec = (int)OMTCodec.UYVY,
                            Width = width, Height = height, Stride = width * 2,
                            FrameRateN = 30, FrameRateD = 1, AspectRatio = 16f / 9f,
                            ColorSpace = OMTColorSpace.BT709, Timestamp = started,
                            Data = pin.AddrOfPinnedObject(), DataLength = picture.Length
                        };
                        int connections = sender.Connections;
                        int returned = sender.Send(frame);
                        if (Calls.Count < 20000) Calls.Add(new(started, Now, epoch, returned, connections));
                        else OmittedCalls++;
                        next = started + 333334;
                    }
                }
            }
            catch (Exception error) { failure = error; }
            finally { pin.Free(); }
        }
        public void Dispose()
        {
            stop.Cancel();
            Require(worker.Join(5000), "Sender worker did not stop");
            lock (gate) sender.Dispose();
            stop.Dispose(); Check();
        }
    }
    public static int Main(string[] args)
    {
        string codec = Path.GetFullPath(Argument(args, "--codec"));
        string storage = Path.GetFullPath(Argument(args, "--storage"));
        string report = Path.GetFullPath(Argument(args, "--report"));
        int rounds = int.Parse(Argument(args, "--rounds", "8"));
        Directory.CreateDirectory(storage);
        Environment.SetEnvironmentVariable("OMT_STORAGE_PATH", storage);
        NativeLibrary.SetDllImportResolver(typeof(OMTSend).Assembly,
            (name, assembly, path) => name == "libvmx" ? NativeLibrary.Load(codec) : IntPtr.Zero);
        if (args.Contains("--sender-child")) return RunSenderChild(args, report);
        int discoveryPort = FreePort();
        OMTSettings.GetInstance().SetString("DiscoveryServer", "omt://127.0.0.1:" + discoveryPort);
        using var discovery = new OMTDiscoveryServer(new IPEndPoint(IPAddress.Loopback, discoveryPort));
        discovery.StartServer();
        if (args.Contains("--sender-processes"))
        {
            try { return RunSenderProcesses(codec, storage, report, rounds, discoveryPort); }
            finally { OMTDiscovery.GetInstance().Dispose(); discovery.StopServer(); }
        }
        Source? source = null;
        OMTReceive? receiver = null;
        string? errorText = null;
        bool passed = true;
        string endpoint = "";
        var results = new List<object>();
        var total = Stopwatch.StartNew();
        try
        {
            source = new Source();
            endpoint = "omt://127.0.0.1:" + source.Port;
            receiver = new OMTReceive(endpoint, OMTFrameType.Video, OMTPreferredVideoFormat.BGRA, OMTReceiveFlags.None);
            long lastTimecode = -1;
            for (int cycle = 0; cycle < rounds; cycle++)
            {
                if (cycle > 0) source.Restart();
                long boundary = source.Boundary;
                var clock = Stopwatch.StartNew();
                int frames = 0, pending = 0, stale = 0;
                double? firstFreshMilliseconds = null;
                var observations = new List<object>();
                while (clock.ElapsedMilliseconds < 8000 && frames < 3)
                {
                    source.Check();
                    OMTMediaFrame frame = default;
                    bool received = receiver.Receive(OMTFrameType.Video, 100, ref frame);
                    if (observations.Count < 256) observations.Add(new
                    {
                        ElapsedMs = clock.Elapsed.TotalMilliseconds, Received = received,
                        ReceiverConnected = receiver.IsConnected(), SenderConnections = source.Connections,
                        Timestamp = received ? frame.Timestamp : (long?)null
                    });
                    if (!received) { pending++; continue; }
                    Require(frame.Width == 1920 && frame.Height == 1080 && frame.Codec == (int)OMTCodec.BGRA &&
                        frame.Data != IntPtr.Zero && frame.Stride >= 7680 && frame.DataLength >= frame.Stride * frame.Height,
                        "Invalid decoded 1080p BGRA frame");
                    if (frame.Timestamp < boundary) { stale++; continue; }
                    Require(frame.Timestamp > lastTimecode, "Fresh video timestamp repeated or regressed");
                    lastTimecode = frame.Timestamp;
                    firstFreshMilliseconds ??= clock.Elapsed.TotalMilliseconds;
                    frames++;
                }
                bool withinTarget = frames >= 3 && firstFreshMilliseconds is double firstFresh && firstFresh <= 4000;
                var drops = source.Drops;
                results.Add(new
                {
                    Cycle = cycle, Frames = frames, PendingCalls = pending, StaleFrames = stale,
                    FirstFreshMs = firstFreshMilliseconds, ElapsedMs = clock.Elapsed.TotalMilliseconds,
                    PassedFourSecondTarget = withinTarget, ReceiverConnected = receiver.IsConnected(),
                    SenderConnections = source.Connections, drops.VideoDrops, drops.AudioDrops, Observations = observations
                });
                Console.WriteLine($"cycle={cycle} fresh={frames} firstMs={firstFreshMilliseconds} pending={pending} targetPassed={withinTarget}");
                if (!withinTarget) { passed = false; break; }
            }
        }
        catch (Exception error) { passed = false; errorText = error.ToString(); }
        finally
        {
            try { receiver?.Dispose(); } catch (Exception error) { passed = false; errorText += "\nReceiver shutdown: " + error; }
            try { source?.Dispose(); } catch (Exception error) { passed = false; errorText += "\nSender shutdown: " + error; }
            OMTDiscovery.GetInstance().Dispose(); discovery.StopServer();
            File.WriteAllText(report, JsonSerializer.Serialize(new
            {
                Passed = passed, Error = errorText, Endpoint = endpoint, Rounds = rounds,
                SDKAssembly = typeof(OMTSend).Assembly.GetName().Version?.ToString(),
                Scope = "Public managed APIs; video-only persistent direct URL, exact listener reuse, real1080p UYVY/VMX decodedBGRA, no frame metadata or audio. Four-second recovery target, eight-second diagnostic ceiling. No private state inspection or SDK edits.",
                DurationSeconds = total.Elapsed.TotalSeconds, Cycles = results,
                OmittedCalls = source?.OmittedCalls ?? 0, Calls = source?.Calls ?? new List<Call>()
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        return passed ? 0 : 1;
    }
}
