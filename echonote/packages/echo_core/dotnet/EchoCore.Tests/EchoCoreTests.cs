using Xunit;

namespace EchoNote.Audio.Tests;

// Same cases as swift/Tests/EchoCoreTests and the JNI androidTest, plus the
// IDisposable contract.
public class EchoCoreTests
{
    /// <summary>A 100 ms chunk (1600 samples at 16 kHz) of a 440 Hz tone at <paramref name="level"/>.</summary>
    private static short[] Chunk(double level, int index) =>
        Enumerable.Range(0, 1600)
            .Select(i =>
            {
                var t = (double)(index * 1600 + i) / 16000;
                return (short)Math.Round(level * 32767 * Math.Sin(2 * Math.PI * 440 * t),
                    MidpointRounding.AwayFromZero);
            })
            .ToArray();

    [Fact]
    public void Pcm16ToFloat()
    {
        Assert.Equal([-1f, 0f, 0.5f, 32767f / 32768], EchoCore.Pcm16ToFloat([-32768, 0, 16384, 32767]));
        Assert.Empty(EchoCore.Pcm16ToFloat([]));
    }

    [Fact]
    public void Pcm16ToFloatIntoDestination()
    {
        var destination = new float[2];
        EchoCore.Pcm16ToFloat([16384, -16384], destination);
        Assert.Equal([0.5f, -0.5f], destination);
        Assert.Throws<ArgumentException>(() => EchoCore.Pcm16ToFloat([1, 2, 3], new float[2]));
    }

    [Fact]
    public void Rms()
    {
        Assert.Equal(0.5f, EchoCore.Rms([16384, -16384, 16384, -16384]));
        Assert.Equal(1f, EchoCore.Rms([-32768]));
        Assert.Equal(0f, EchoCore.Rms([]));
    }

    [Fact]
    public void Waveform()
    {
        Assert.Equal([0.25f, 0.5f], EchoCore.Waveform([0, 8192, -16384, 0], buckets: 2));
        Assert.Equal([0.5f, 1f], EchoCore.Waveform([16384, -32768], buckets: 5));
        Assert.Empty(EchoCore.Waveform([1, 2], buckets: 0));
        Assert.Empty(EchoCore.Waveform([], buckets: 4));
    }

    [Fact]
    public void VadQuietSpeechQuiet()
    {
        using var vad = new EchoVad();
        var decisions = new List<bool>();
        for (var i = 0; i < 10; i++) decisions.Add(vad.Process(Chunk(0.0005, i)));
        for (var i = 10; i < 20; i++) decisions.Add(vad.Process(Chunk(0.2, i)));
        for (var i = 20; i < 30; i++) decisions.Add(vad.Process(Chunk(0.0005, i)));
        Assert.Equal(
            Enumerable.Repeat(false, 10).Concat(Enumerable.Repeat(true, 10)).Concat(Enumerable.Repeat(false, 10)),
            decisions);
        Assert.False(vad.Process([]));
    }

    [Fact]
    public void VadDefaultsMatchTheHeader()
    {
        var c = EcVadConfig.Default;
        Assert.Equal(0.005f, c.InitialNoiseFloor);
        Assert.Equal(0.0015f, c.RmsMin);
        Assert.Equal(2.5f, c.VoiceRatio);
        Assert.Equal(0.01f, c.NoiseFloorCap);
        Assert.Equal(0.5f, c.FallRate);
        Assert.Equal(0.0005f, c.RiseRate);
    }

    [Fact]
    public void VadDisposeTwiceThenUseThrows()
    {
        var vad = new EchoVad();
        vad.Process(Chunk(0.2, 0));
        vad.Reset();
        vad.Dispose();
        vad.Dispose();
        Assert.Throws<ObjectDisposedException>(() => vad.Process(Chunk(0.2, 1)));
        Assert.Throws<ObjectDisposedException>(() => vad.Reset());
    }

    [Fact]
    public void VadFreedByFinalizerWhenNotDisposed()
    {
        // Nothing to observe; a double free or crash in ReleaseHandle would
        // fail the run.
        CreateAndDrop();
        GC.Collect();
        GC.WaitForPendingFinalizers();

        static void CreateAndDrop() => new EchoVad().Process(Chunk(0.2, 0));
    }
}
