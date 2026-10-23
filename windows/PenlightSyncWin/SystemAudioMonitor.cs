using NAudio.Wave;
using PenlightSync.Core;

namespace PenlightSync.Win;

/// <summary>
/// Windows counterpart of SystemAudioMonitor.swift: listens to the default output device with WASAPI loopback
/// (no extra permission) and reports detected beats (strength, current tempo) on the UI thread. Audio is analyzed in memory only.
/// </summary>
internal sealed class SystemAudioMonitor : IDisposable
{
    private readonly SynchronizationContext _ui;
    private readonly Action<double, double?> _onBeat;
    private readonly Action<string> _onFailure;
    private readonly WasapiLoopbackCapture _capture = new();
    private readonly BeatDetector _detector;
    private readonly int _channels;
    private readonly int _bytesPerSample;
    private readonly bool _isFloat;
    private float[] _mono = Array.Empty<float>();
    private bool _stopping;

    public SystemAudioMonitor(SynchronizationContext ui, Action<double, double?> onBeat, Action<string> onFailure)
    {
        _ui = ui;
        _onBeat = onBeat;
        _onFailure = onFailure;
        var format = _capture.WaveFormat;
        _channels = Math.Max(1, format.Channels);
        _bytesPerSample = format.BitsPerSample / 8;
        var encoding = format is WaveFormatExtensible extensible ? extensible.ToStandardWaveFormat().Encoding : format.Encoding;
        _isFloat = encoding == WaveFormatEncoding.IeeeFloat;
        if (!(_isFloat && _bytesPerSample == 4) && !(!_isFloat && _bytesPerSample == 2))
            throw new NotSupportedException($"不支援的音訊格式：{format}");
        _detector = new BeatDetector(format.SampleRate);
        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += OnStopped;
    }

    public void Start() => _capture.StartRecording();

    private void OnData(object? sender, WaveInEventArgs args)
    {
        // Downmix interleaved frames to mono floats.
        var frameBytes = _bytesPerSample * _channels;
        var frames = args.BytesRecorded / frameBytes;
        if (_mono.Length < frames) _mono = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            for (var channel = 0; channel < _channels; channel++)
            {
                var offset = frame * frameBytes + channel * _bytesPerSample;
                sum += _isFloat ? BitConverter.ToSingle(args.Buffer, offset) : BitConverter.ToInt16(args.Buffer, offset) / 32768f;
            }
            _mono[frame] = sum / _channels;
        }
        var beats = _detector.Process(_mono.AsSpan(0, frames));
        var bpm = _detector.Bpm;
        if (beats.Count > 0) _ui.Post(_ => beats.ForEach(strength => _onBeat(strength, bpm)), null);
    }

    private void OnStopped(object? sender, StoppedEventArgs args)
    {
        if (_stopping || args.Exception is not { } error) return;
        _ui.Post(_ => _onFailure(error.Message), null);
    }

    public void Dispose()
    {
        _stopping = true;
        _capture.DataAvailable -= OnData;
        try { _capture.StopRecording(); } catch (Exception) { }
        _capture.Dispose();
    }
}
