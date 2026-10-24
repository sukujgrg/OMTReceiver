using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using libomtnet;

internal static class Program
{
    private const OMTFrameType Media = OMTFrameType.Video | OMTFrameType.Audio;
    private static readonly long Origin = Stopwatch.GetTimestamp();
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static string Marker(int epoch) => "<epoch>" + epoch.ToString("D8") + "</epoch>";
    private static long Now => (long)((Stopwatch.GetTimestamp() - Origin) * (10_000_000.0 / Stopwatch.Frequency));

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

    private static OMTReceive Receiver(string address) =>
        new(address, Media, OMTPreferredVideoFormat.UYVY, OMTReceiveFlags.None);

    private static void WaitFor(Func<bool> condition, Source source, string description, int milliseconds = 5000)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            source.Check();
            Require(clock.ElapsedMilliseconds < milliseconds, "Timed out: " + description);
            Thread.Sleep(2);
        }
    }

    private sealed record FrameCall(string Kind, long Started, long Finished, int Epoch, int Returned, int Connections);
    private sealed record Reception(int Epoch, int Video, int Audio, double Seconds, int Connections,
        long VideoDrops, long AudioDrops);

    private sealed class Source : IDisposable
    {
        private readonly object gate = new();
        private readonly string name;
        private readonly Thread thread;
        private readonly CancellationTokenSource stop = new();
        private OMTSend sender;
        private Exception? failure;
        private int epoch = 1;
        private long epochStarted = Now;
        private readonly bool audioMetadata;
        public readonly List<FrameCall> Calls = new(20000);
        public int OmittedCalls { get; private set; }

        public Source(bool audioMetadata = false)
        {
            this.audioMetadata = audioMetadata;
            name = "Public API lifecycle " + Guid.NewGuid().ToString("N");
            sender = new OMTSend(name, OMTQuality.Medium);
            thread = new Thread(Produce) { IsBackground = true, Name = "paced-public-api-sender" };
            thread.Start();
        }

        public int Epoch => Volatile.Read(ref epoch);
        public int AdvanceEpoch()
        {
            lock (gate)
            {
                epochStarted = Now;
                return Interlocked.Increment(ref epoch);
            }
        }
        public long EpochStarted { get { lock (gate) return epochStarted; } }
        public int Connections { get { lock (gate) return sender.Connections; } }
        public string DirectURL { get { lock (gate) return "omt://127.0.0.1:" + sender.Port; } }
        public string Address { get { lock (gate) return sender.Address; } }

        public (long Video, long Audio) Drops()
        {
            lock (gate) return (sender.GetVideoStatistics().FramesDropped, sender.GetAudioStatistics().FramesDropped);
        }

        public void Restart()
        {
            lock (gate)
            {
                sender.Dispose();
                sender = new OMTSend(name, OMTQuality.Medium);
                AdvanceEpoch();
            }
        }

        public void Check()
        {
            var error = Volatile.Read(ref failure);
            if (error != null) throw new InvalidOperationException("Producer failed", error);
        }

        private void Produce()
        {
            const int width = 320, height = 180;
            byte[] picture = new byte[width * height * 2];
            for (int index = 0; index < picture.Length; index += 4)
            {
                picture[index] = 100;
                picture[index + 1] = (byte)(32 + (index / 4) % 180);
                picture[index + 2] = 150;
                picture[index + 3] = (byte)(32 + (index / 8) % 180);
            }
            float[] pcm = new float[960 * 2];
            for (int sample = 0; sample < 960; sample++)
            {
                pcm[sample] = (float)(0.2 * Math.Sin(sample * 2 * Math.PI * 400 / 48000));
                pcm[sample + 960] = (float)(0.2 * Math.Sin(sample * 2 * Math.PI * 600 / 48000));
            }
            var videoPin = GCHandle.Alloc(picture, GCHandleType.Pinned);
            var audioPin = GCHandle.Alloc(pcm, GCHandleType.Pinned);
            IntPtr marker = Marshal.AllocHGlobal(128);
            long nextVideo = Now, nextAudio = Now;
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    long now = Now;
                    if (now >= nextAudio)
                    {
                        Send(new OMTMediaFrame
                        {
                            Type = OMTFrameType.Audio, Codec = (int)OMTCodec.FPA1,
                            SampleRate = 48000, Channels = 2, SamplesPerChannel = 960,
                            Data = audioPin.AddrOfPinnedObject(), DataLength = pcm.Length * 4,
                            FrameMetadata = audioMetadata ? marker : IntPtr.Zero
                        });
                        nextAudio = Now + 200000;
                    }
                    now = Now;
                    if (now >= nextVideo)
                    {
                        Send(new OMTMediaFrame
                        {
                            Type = OMTFrameType.Video, Codec = (int)OMTCodec.UYVY,
                            Width = width, Height = height, Stride = width * 2,
                            FrameRateN = 30, FrameRateD = 1, AspectRatio = 16f / 9f,
                            ColorSpace = OMTColorSpace.BT709,
                            Data = videoPin.AddrOfPinnedObject(), DataLength = picture.Length,
                            FrameMetadata = marker
                        });
                        nextVideo = Now + 333334;
                    }
                    Thread.Sleep(1);
                }
            }
            catch (Exception error) { failure = error; }
            finally
            {
                Marshal.FreeHGlobal(marker);
                audioPin.Free();
                videoPin.Free();
            }
        }

        private void Send(OMTMediaFrame frame)
        {
            lock (gate)
            {
                int currentEpoch = Epoch;
                if (frame.FrameMetadata != IntPtr.Zero)
                {
                    byte[] metadata = Encoding.UTF8.GetBytes(Marker(currentEpoch) + "\0");
                    Marshal.Copy(metadata, 0, frame.FrameMetadata, metadata.Length);
                    frame.FrameMetadataLength = metadata.Length;
                }
                long started = Now;
                frame.Timestamp = started;
                int connections = sender.Connections;
                int returned = sender.Send(frame);
                var call = new FrameCall(frame.Type.ToString(), started, Now, currentEpoch, returned, connections);
                if (Calls.Count < 20000) Calls.Add(call); else OmittedCalls++;
            }
        }

        public void Dispose()
        {
            stop.Cancel();
            Require(thread.Join(5000), "Producer did not stop");
            lock (gate) sender.Dispose();
            stop.Dispose();
            Check();
        }
    }

    private static Reception ReceiveFresh(OMTReceive receiver, Source source, int epoch, int needed = 10,
        int timeoutMilliseconds = 8000)
    {
        int video = 0, audio = 0;
        long lastVideo = -1, lastAudio = -1;
        var clock = Stopwatch.StartNew();
        while (video < needed || audio < needed)
        {
            source.Check();
            Require(clock.ElapsedMilliseconds < timeoutMilliseconds,
                $"No fresh A/V for epoch {epoch}: video={video}, audio={audio}, connected={receiver.IsConnected()}");
            OMTMediaFrame frame = default;
            if (!receiver.Receive(Media, 20, ref frame)) continue;
            Require(frame.Data != IntPtr.Zero && frame.DataLength > 0, "Empty decoded media");
            if (frame.Timestamp < source.EpochStarted) continue;
            if (frame.Type == OMTFrameType.Video)
            {
                if (frame.FrameMetadataLength <= 0 || frame.FrameMetadata == IntPtr.Zero ||
                    Marshal.PtrToStringUTF8(frame.FrameMetadata) != Marker(epoch)) continue;
                Require(frame.Width == 320 && frame.Height == 180, "Wrong decoded video dimensions");
                Require(frame.Timestamp > lastVideo, "Video timestamp repeated/regressed");
                lastVideo = frame.Timestamp;
                video++;
            }
            else if (frame.Type == OMTFrameType.Audio)
            {
                Require(frame.SampleRate == 48000 && frame.Channels == 2 && frame.SamplesPerChannel == 960,
                    "Wrong decoded audio shape");
                Require(frame.Timestamp > lastAudio, "Audio timestamp repeated/regressed");
                lastAudio = frame.Timestamp;
                audio++;
            }
        }
        Require(receiver.IsConnected(), "Receiver lost its connection after fresh media");
        var drops = source.Drops();
        return new Reception(epoch, video, audio, clock.Elapsed.TotalSeconds, source.Connections, drops.Video, drops.Audio);
    }

    private static object GracefulReceiverCycles(Source source, int rounds)
    {
        var results = new List<Reception>();
        for (int round = 0; round < rounds; round++)
        {
            int epoch = source.AdvanceEpoch();
            using (var receiver = Receiver(source.DirectURL)) results.Add(ReceiveFresh(receiver, source, epoch));
            WaitFor(() => source.Connections == 0, source, "receiver dispose removes both channels");
        }
        return results;
    }

    private static Process StartChild(string address, string codec, string discovery, string storage)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false
        };
        start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        foreach (string argument in new[] { "--receiver-child", "--address", address, "--codec", codec,
            "--discovery", discovery, "--storage", storage }) start.ArgumentList.Add(argument);
        return Process.Start(start)!;
    }

    private static object AbruptReceiverCycles(Source source, int rounds, string codec, string discovery, string storage)
    {
        var results = new List<object>();
        for (int round = 0; round < rounds; round++)
        {
            int epoch = source.AdvanceEpoch();
            using var child = StartChild(source.DirectURL, codec, discovery, Path.Combine(storage, "child-" + round));
            try
            {
                string? ready = child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
                Require(ready == "READY", "Receiver child did not decode media: " + ready);
                Require(source.Connections == 2, "Receiver child did not establish two media channels");
                child.Kill(entireProcessTree: true);
                Require(child.WaitForExit(5000), "Receiver child did not exit");
                WaitFor(() => source.Connections == 0, source, "receiver process exit removes both channels");
                source.AdvanceEpoch();
                using var receiver = Receiver(source.DirectURL);
                results.Add(new { KilledEpoch = epoch, Recovered = ReceiveFresh(receiver, source, source.Epoch) });
            }
            finally
            {
                if (!child.HasExited) { child.Kill(entireProcessTree: true); child.WaitForExit(5000); }
            }
            WaitFor(() => source.Connections == 0, source, "replacement receiver dispose");
        }
        return results;
    }

    private static object SenderRestartCycles(Source source, int rounds)
    {
        var results = new List<Reception>();
        using var receiver = Receiver(source.Address);
        _ = ReceiveFresh(receiver, source, source.Epoch);
        for (int round = 0; round < rounds; round++)
        {
            source.Restart();
            results.Add(ReceiveFresh(receiver, source, source.Epoch));
        }
        return results;
    }

    private static int ReceiverChild(string address)
    {
        using var receiver = Receiver(address);
        int video = 0, audio = 0;
        bool announced = false;
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(20))
        {
            OMTMediaFrame frame = default;
            if (!receiver.Receive(Media, 20, ref frame)) continue;
            if (frame.Type == OMTFrameType.Video) video++;
            if (frame.Type == OMTFrameType.Audio) audio++;
            if (!announced && video >= 10 && audio >= 10)
            {
                announced = true;
                Console.WriteLine("READY");
                Console.Out.Flush();
            }
        }
        return 0;
    }

    private static object AudioMetadataProbe(Source source)
    {
        using var receiver = Receiver(source.DirectURL);
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < 5000)
        {
            OMTMediaFrame frame = default;
            if (!receiver.Receive(Media, 20, ref frame) || frame.Type != OMTFrameType.Audio) continue;
            int firstSampleBits = Marshal.ReadInt32(frame.Data);
            string? metadata = frame.FrameMetadata != IntPtr.Zero && frame.FrameMetadataLength > 0
                ? Marshal.PtrToStringUTF8(frame.FrameMetadata, frame.FrameMetadataLength - 1) : null;
            return new
            {
                ExpectedMetadata = Marker(source.Epoch), ActualMetadata = metadata,
                frame.FrameMetadataLength, ExpectedFirstPcmBits = 0, ActualFirstPcmBits = firstSampleBits,
                MetadataMatches = metadata == Marker(source.Epoch), PcmPrefixMatches = firstSampleBits == 0
            };
        }
        throw new InvalidOperationException("No audio received for metadata probe");
    }

    private static string Argument(string[] args, string name, string? fallback = null)
    {
        int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback ?? throw new ArgumentException(name);
    }

    public static int Main(string[] args)
    {
        string codec = Path.GetFullPath(Argument(args, "--codec"));
        string storage = Path.GetFullPath(Argument(args, "--storage"));
        Directory.CreateDirectory(storage);
        Environment.SetEnvironmentVariable("OMT_STORAGE_PATH", storage);
        NativeLibrary.SetDllImportResolver(typeof(OMTSend).Assembly,
            (name, assembly, path) => name == "libvmx" ? NativeLibrary.Load(codec) : IntPtr.Zero);
        bool child = args.Contains("--receiver-child");
        int port = child ? 0 : FreePort();
        string discoveryURL = Argument(args, "--discovery", "omt://127.0.0.1:" + port);
        OMTSettings.GetInstance().SetString("DiscoveryServer", discoveryURL);
        OMTSettings.GetInstance().SetInteger("NetworkPortStart", 0);
        OMTSettings.GetInstance().SetInteger("NetworkPortEnd", 0);
        if (child) return ReceiverChild(Argument(args, "--address"));

        string reportPath = Path.GetFullPath(Argument(args, "--report"));
        int rounds = int.Parse(Argument(args, "--rounds", "8"));
        using var server = new OMTDiscoveryServer(new IPEndPoint(IPAddress.Loopback, port));
        server.StartServer();
        var cases = new List<object>();
        var clock = Stopwatch.StartNew();
        Source? source = null;
        int failures = 0;
        try
        {
            bool metadataProbe = args.Contains("--audio-metadata-probe");
            source = new Source(metadataProbe);
            if (metadataProbe)
            {
                object result = AudioMetadataProbe(source);
                string json = JsonSerializer.Serialize(result);
                using var parsed = JsonDocument.Parse(json);
                bool passed = parsed.RootElement.GetProperty("MetadataMatches").GetBoolean() &&
                    parsed.RootElement.GetProperty("PcmPrefixMatches").GetBoolean();
                if (!passed) failures++;
                cases.Add(new { Name = "audio frame metadata and PCM preservation", Passed = passed, Result = result });
                Console.WriteLine((passed ? "PASS " : "FAIL ") + "audio frame metadata and PCM preservation: " + json);
            }
            else foreach (var test in new (string Name, Func<object> Run)[]
            {
                ("receiver dispose/recreate", () => GracefulReceiverCycles(source, rounds)),
                ("receiver process exit/recreate", () => AbruptReceiverCycles(source, rounds, codec, discoveryURL, storage)),
                ("sender restart with persistent receiver", () => SenderRestartCycles(source, rounds))
            })
            {
                try
                {
                    object result = test.Run();
                    cases.Add(new { test.Name, Passed = true, Result = result });
                    Console.WriteLine("PASS " + test.Name);
                }
                catch (Exception error)
                {
                    failures++;
                    cases.Add(new { test.Name, Passed = false, Error = error.ToString() });
                    Console.WriteLine("FAIL " + test.Name + ": " + error.Message);
                    break;
                }
            }
        }
        catch (Exception error)
        {
            failures++;
            cases.Add(new { Name = "setup", Passed = false, Error = error.ToString() });
        }
        finally
        {
            try { source?.Dispose(); } catch (Exception error) { failures++; cases.Add(new { Name = "shutdown", Passed = false, Error = error.ToString() }); }
            OMTDiscovery.GetInstance().Dispose();
            server.StopServer();
            var calls = source?.Calls ?? new List<FrameCall>();
            File.WriteAllText(reportPath, JsonSerializer.Serialize(new
            {
                SDKAssembly = typeof(OMTSend).Assembly.GetName().Version?.ToString(),
                CodecPath = codec, RoundsPerCase = rounds, DurationSeconds = clock.Elapsed.TotalSeconds,
                Scope = "Public compiled-library APIs only; loopback discovery, real VMX/FPA1, 320x180 video at up to30fps and stereo48k/960 audio at up to50blocks/s. No internal pool inspection or SDK edits; lifecycle check, not throughput or physical A/V qualification.",
                Passed = failures == 0, Cases = cases, OmittedCalls = source?.OmittedCalls ?? 0, Calls = calls
            }, JsonOptions));
        }
        return failures == 0 ? 0 : 1;
    }
}
