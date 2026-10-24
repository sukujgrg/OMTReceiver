using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using libomtnet;

// Keep the real channel, protocol and pool sources. Suppress only file logging
// so this loopback-only test never creates the SDK's user storage directory.
namespace libomtnet
{
    internal static class OMTLogging
    {
        public static void Write(string message, string category) { }
    }
}

internal static class Program
{
    private static void Require(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private sealed class Link : IDisposable
    {
        public readonly Socket Peer;
        public readonly OMTChannel Channel;
        public readonly OMTSocketAsyncPool Pool;

        public Link()
        {
            using var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            listener.ReceiveBufferSize = 65536;
            listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            listener.Listen(1);
            var accept = listener.AcceptAsync();
            Peer = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            Peer.NoDelay = true;
            Peer.ReceiveBufferSize = 65536;
            Peer.SendTimeout = 3000;
            Peer.Connect(listener.LocalEndPoint);
            var socket = accept.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
            Channel = new OMTChannel(socket, OMTFrameType.Metadata, null, null, false);
            // Deliberately constrain the transport so a paused peer fills the
            // four-slot pool even on loopback. This is not a throughput test.
            socket.SendBufferSize = 4096;
            Pool = (OMTSocketAsyncPool)typeof(OMTChannel)
                .GetField("sendpool", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(Channel);
            Channel.StartReceive();
        }

        public void Subscribe()
        {
            using var frame = new OMTFrame(OMTFrameType.Metadata,
                OMTBuffer.FromMetadata(OMTMetadataConstants.CHANNEL_SUBSCRIBE_VIDEO));
            var wire = Bytes(frame);
            int offset = 0;
            while (offset < wire.Length)
            {
                int count = Peer.Send(wire, offset, wire.Length - offset, SocketFlags.None);
                Require(count > 0, "Socket closed before the subscription was sent");
                offset += count;
            }
            Require(SpinWait.SpinUntil(() => Channel.IsVideo(), 3000), "Video subscription was not parsed");
        }

        public void Dispose()
        {
            Channel.Dispose();
            Peer.Dispose();
        }
    }

    private static OMTFrame Video(int bytes, long timestamp)
    {
        var frame = new OMTFrame(OMTFrameType.Video, bytes, true);
        frame.SetDataLength(bytes);
        for (int i = 0; i < bytes; i++) frame.Data.Buffer[i] = (byte)(i * 17 + timestamp);
        frame.ConfigureVideo((int)OMTCodec.VMX1, 1920, 1080, 30, 1, 16f / 9f,
            OMTVideoFlags.None, OMTColorSpace.BT709);
        frame.Timestamp = timestamp;
        return frame;
    }

    private static byte[] Bytes(OMTFrame frame)
    {
        var wire = new byte[frame.Length];
        frame.WriteHeaderTo(wire, 0, wire.Length);
        int header = frame.HeaderLength + frame.ExtendedHeaderLength;
        frame.WriteDataTo(wire, 0, header, wire.Length - header);
        return wire;
    }

    private static async Task<byte[]> Read(Socket peer, int length)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var bytes = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int count = await peer.ReceiveAsync(bytes.AsMemory(offset), SocketFlags.None, deadline.Token);
            Require(count > 0, "Socket closed before all accepted bytes were received");
            offset += count;
        }
        return bytes;
    }

    private static void AllSlotsReturned(Link link)
    {
        Require(SpinWait.SpinUntil(() => link.Pool.Count == 4, 3000),
            $"Expected four reusable slots after completion, got {link.Pool.Count}");
    }

    private static Task UnsubscribedIsNotPressure()
    {
        using var link = new Link();
        using var frame = Video(128, 1);
        Require(link.Channel.Send(frame) == 0, "Unsubscribed channel accepted video");
        Require(link.Channel.GetStatistics().FramesDropped == 0, "Unsubscribed zero was counted as a drop");
        Require(link.Pool.Count == 4, "Unsubscribed frame rented a send slot");
        return Task.CompletedTask;
    }

    private static async Task OversizeIsDistinctFromPressure()
    {
        using var link = new Link();
        link.Subscribe();
        using (var oversized = Video(OMTConstants.VIDEO_MAX_SIZE, 2))
        {
            Require(link.Channel.Send(oversized) == 0, "Oversized frame was accepted");
            Require(link.Channel.GetStatistics().FramesDropped == 1, "Oversized frame was not counted once");
            Require(link.Pool.Count == 4, "Oversized frame consumed a send slot");
        }
        using var valid = Video(128, 3);
        var expected = Bytes(valid);
        var reading = Read(link.Peer, expected.Length);
        Require(link.Channel.Send(valid) == expected.Length, "Valid frame failed after oversized rejection");
        Require((await reading).SequenceEqual(expected), "Valid frame changed after oversized rejection");
        AllSlotsReturned(link);
    }

    private static async Task PressureRejectsOneThenRecovers()
    {
        using var link = new Link();
        link.Subscribe();
        var expected = new List<byte>();
        for (int i = 1; i <= 4; i++)
        {
            using var frame = Video(1048576, i);
            var wire = Bytes(frame);
            Require(link.Channel.Send(frame) == wire.Length, $"Initial send {i} was rejected");
            expected.AddRange(wire);
        }
        Require(link.Pool.Count == 0, "Paused peer did not fill the four-slot pool");
        using (var rejected = Video(128, 5))
            Require(link.Channel.Send(rejected) == 0, "Full pool did not reject the next frame");
        var blocked = link.Channel.GetStatistics();
        Require(blocked.Frames == 4 && blocked.FramesDropped == 1, "Pressure counters did not report four accepted and one rejected");
        Require((await Read(link.Peer, expected.Count)).SequenceEqual(expected), "Accepted stream was truncated, reordered or changed");
        AllSlotsReturned(link);
        using var recovered = Video(128, 6);
        var final = Bytes(recovered);
        var reading = Read(link.Peer, final.Length);
        Require(link.Channel.Send(recovered) == final.Length, "Channel did not recover after pressure cleared");
        Require((await reading).SequenceEqual(final), "Recovered frame bytes changed");
        AllSlotsReturned(link);
        var result = link.Channel.GetStatistics();
        Require(result.Frames == 5 && result.FramesDropped == 1, "Recovery lost or added a drop");
    }

    public static async Task<int> Main()
    {
        var tests = new (string name, Func<Task> run)[]
        {
            ("unsubscribed zero return is not a channel drop", UnsubscribedIsNotPressure),
            ("oversized rejection preserves slots and recovers", OversizeIsDistinctFromPressure),
            ("full pool rejects one frame then resumes byte-identical delivery", PressureRejectsOneThenRecovers)
        };
        int failures = 0;
        foreach (var test in tests)
        {
            var elapsed = Stopwatch.StartNew();
            try { await test.run(); Console.WriteLine($"PASS {test.name} ({elapsed.ElapsedMilliseconds} ms)"); }
            catch (Exception error) { failures++; Console.WriteLine($"FAIL {test.name}: {error.GetType().Name}: {error.Message}"); }
        }
        return failures == 0 ? 0 : 1;
    }
}
