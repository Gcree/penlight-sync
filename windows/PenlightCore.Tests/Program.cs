using PenlightSync.Core;

// Mirrors the Swift self-tests so the Windows port is checked against the same protocol vectors and color cases.
var failures = 0;
void Check(bool condition, string name)
{
    if (condition) return;
    failures++;
    Console.Error.WriteLine($"FAIL: {name}");
}

(Rgb, string)[] vectors =
{
    (new Rgb(255, 0, 0), "3644466a660f0d623318df1966e5dc63"),
    (new Rgb(0, 255, 0), "205cd7598c7fc8712ae2d380d6eee13f"),
    (new Rgb(0, 0, 255), "847f6d09abe341f384b8de8736b40833"),
    (new Rgb(0, 0, 0), "ed3823c3d92e1b9d69000194db6c5244"),
    (new Rgb(255, 255, 255), "5c55abaf41e5fcf2b04b1e9d713967bc"),
};
foreach (var (color, expected) in vectors)
{
    Check(Convert.ToHexString(PenlightProtocol.Encode(color)).ToLowerInvariant() == expected, $"protocol vector {color}");
}

foreach (var solid in new[] { new Rgb(235, 15, 10), new Rgb(10, 220, 30), new Rgb(12, 18, 240), new Rgb(255, 255, 255), new Rgb(0, 0, 0), new Rgb(128, 128, 128) })
{
    Check(AverageColor.Find(new[] { solid.Red, solid.Green, solid.Blue, (byte)255 }, 1, 1, 4) == solid, $"solid RGBA {solid}");
    Check(AverageColor.Find(new[] { solid.Blue, solid.Green, solid.Red, (byte)255 }, 1, 1, 4, bgra: true) == solid, $"solid BGRA {solid}");
}

Check(AverageColor.Find(new byte[] { 255, 0, 0, 255, 0, 0, 255, 255 }, 2, 1, 8) == new Rgb(128, 0, 128), "mixed red/blue averages to purple");

byte[] padded =
{
    240, 8, 10, 255, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE, 0xEE,
    240, 8, 10, 255, 0, 0, 0, 0, 0xDD, 0xDD, 0xDD, 0xDD,
};
Check(AverageColor.Find(padded, 2, 2, 12) == new Rgb(240, 8, 10), "padded rows and transparent pixels");
Check(AverageColor.Find(new byte[] { 0, 0, 0, 255 }, 2, 1, 8) == null, "malformed buffer");
Check(AverageColor.Find(new byte[] { 0, 0, 0, 0 }, 1, 1, 4) == null, "fully transparent buffer");

// Video sampling: same cases as ScreenColorTests.swift.
byte[] Frame(int width, int height, Rgb fill)
{
    var bytes = new byte[width * height * 4];
    for (var i = 0; i < width * height; i++) (bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]) = (fill.Red, fill.Green, fill.Blue, 255);
    return bytes;
}
void Set(byte[] bytes, int width, int x, int y, Rgb color) =>
    (bytes[(y * width + x) * 4], bytes[(y * width + x) * 4 + 1], bytes[(y * width + x) * 4 + 2]) = (color.Red, color.Green, color.Blue);

var black = new Rgb(0, 0, 0);
var subtitleWhite = new Rgb(255, 255, 255);
var letterboxed = Frame(16, 12, black);
for (var y = 2; y < 10; y++) for (var x = 0; x < 16; x++) Set(letterboxed, 16, x, y, new Rgb(220, 20, 20));
for (var x = 4; x < 12; x++) Set(letterboxed, 16, x, 8, subtitleWhite);
Check(AverageColor.Find(letterboxed, 16, 12, 64) == new Rgb(220, 20, 20), "letterbox bars and subtitles are ignored");

var pillarboxed = Frame(16, 8, black);
for (var y = 0; y < 8; y++) for (var x = 3; x < 13; x++) Set(pillarboxed, 16, x, y, new Rgb(20, 40, 200));
Check(AverageColor.Find(pillarboxed, 16, 8, 64) == new Rgb(20, 40, 200), "pillarbox bars are ignored");
Check(AverageColor.Find(Frame(8, 8, black), 8, 8, 32) == black, "solid black stays black");
Check(AverageColor.Find(Frame(8, 8, subtitleWhite), 8, 8, 32) == subtitleWhite, "solid white stays white");

var sky = Frame(8, 8, new Rgb(0, 160, 0));
for (var y = 0; y < 4; y++) for (var x = 0; x < 8; x++) Set(sky, 8, x, y, subtitleWhite);
Check(AverageColor.Find(sky, 8, 8, 32)!.Value.Red > 100, "white above the subtitle zone still counts");

var centered = Frame(9, 9, new Rgb(0, 0, 255));
for (var y = 3; y < 6; y++) for (var x = 3; x < 6; x++) Set(centered, 9, x, y, new Rgb(255, 0, 0));
Check(AverageColor.Find(centered, 9, 9, 36)!.Value.Red >= 255 * 9 / 81 + 5, "center pixels weigh more than corners");

// LightEngine: same cases as LightEngineTests.swift.
var red = new Rgb(255, 0, 0);
var blue = new Rgb(0, 0, 255);
var engine = new LightEngine(0.6, breathing: false) { SceneCuts = false };
Check(engine.Step(0.05) == null, "no output before first sample");
engine.SetTarget(red);
Check(engine.Step(0.05) == red, "first sample shows immediately");
engine.SetTarget(blue);
var firstFrame = engine.Step(0.05)!.Value;
Check(firstFrame.Red is < 255 and > 128 && firstFrame.Blue is > 0 and < 128, $"one frame is partway {firstFrame}");
var previousBlue = firstFrame.Blue;
var monotonic = true;
for (var i = 0; i < 11; i++)
{
    var frame = engine.Step(0.05)!.Value;
    monotonic &= frame.Blue >= previousBlue;
    previousBlue = frame.Blue;
}
Check(monotonic, "fade never reverses");
Check(engine.Step(0)!.Value.Blue >= 240, "fade ~95% done after fadeTime");
for (var i = 0; i < 40; i++) engine.Step(0.05);
Check(engine.Step(0.05) == blue, "fade settles on target");

var instant = new LightEngine(0, breathing: false);
instant.SetTarget(red);
instant.Step(0.05);
instant.SetTarget(blue);
Check(instant.Step(0.05) == blue, "fadeTime 0 switches instantly");

var breath = new LightEngine(0.6, breathing: true);
var white = new Rgb(200, 200, 200);
breath.SetTarget(white);
int minimum = 255, maximum = 0;
for (var i = 0; i < 200; i++)
{
    var frame = breath.Step(0.05)!.Value;
    minimum = Math.Min(minimum, frame.Red);
    maximum = Math.Max(maximum, frame.Red);
}
Check(maximum == 200, $"breathing returns to full brightness (max {maximum})");
Check(minimum is < 160 and >= 139, $"breathing dims to about 70% (min {minimum})");
breath.SetTarget(red);
var changing = breath.Step(0.05)!.Value;
Check(changing.Red > 0 && changing.Blue > 0, $"color change starts fading {changing}");
var redMinimum = 255;
for (var i = 0; i < 200; i++) redMinimum = Math.Min(redMinimum, breath.Step(0.05)!.Value.Red);
Check(redMinimum < 200, $"breathing resumes after the new color settles (min {redMinimum})");

var steady = new LightEngine(0.6, breathing: false);
steady.SetTarget(white);
var held = true;
for (var i = 0; i < 200; i++) held &= steady.Step(0.05) == white;
Check(held, "breathing off holds steady");

// Scene cuts: a big jump lands within ~0.2 s; a small change fades normally.
var cuts = new LightEngine(0.6, breathing: false);
cuts.SetTarget(red);
cuts.Step(0.05);
cuts.SetTarget(blue);
var cutFrame = cuts.Step(0.05)!.Value;
for (var i = 0; i < 3; i++) cutFrame = cuts.Step(0.05)!.Value;
Check(cutFrame.Blue >= 240, $"scene cut lands within ~0.2 s {cutFrame}");
cuts.SetTarget(new Rgb(0, 60, 255));
var drift = cuts.Step(0.05)!.Value;
Check(drift.Green is > 0 and < 30, $"small change fades normally {drift}");

// Grading: vibrance keeps hue and peak, leaves grays; floor lifts dark colors.
var graded = LightEngine.Grade(new Rgb(150, 120, 110), 0.5, 0);
Check(graded[0] == 150 && graded[1] < 120 && graded[2] < 110 && graded[2] < graded[1], $"vibrance raises saturation {string.Join(",", graded)}");
Check(LightEngine.Grade(new Rgb(150, 120, 110), 0, 0).SequenceEqual(new double[] { 150, 120, 110 }), "vibrance 0 leaves colors");
Check(LightEngine.Grade(new Rgb(90, 90, 90), 1, 0).SequenceEqual(new double[] { 90, 90, 90 }), "gray stays gray");
var darkRed = LightEngine.Grade(new Rgb(20, 10, 0), 0, 0.2);
Check(Math.Abs(darkRed[0] - 51) < 0.01 && Math.Abs(darkRed[1] - 25.5) < 0.01, "floor scales dark colors up");
Check(LightEngine.Grade(black, 0, 0.2).SequenceEqual(new double[] { 51, 51, 51 }), "floor lights black as dim white");
Check(LightEngine.Grade(new Rgb(200, 0, 0), 0, 0.2).SequenceEqual(new double[] { 200, 0, 0 }), "floor leaves bright colors");

// Beat sync: dims between beats, pops on beats, releases in silence.
var music = new LightEngine(0.6, breathing: false) { BeatSync = true };
music.SetTarget(white);
int lowest = 255, peakAfterBeat = 0;
for (var frameIndex = 0; frameIndex < 80; frameIndex++)
{
    if (frameIndex % 10 == 0) music.Beat(1);
    var frame = music.Step(0.05)!.Value;
    if (frameIndex < 40) continue;
    lowest = Math.Min(lowest, frame.Red);
    if (frameIndex % 10 == 0) peakAfterBeat = Math.Max(peakAfterBeat, frame.Red);
}
Check(music.MusicDetected, "steady beats engage beat sync");
Check(peakAfterBeat >= 185, $"a beat lifts the lamp near full brightness ({peakAfterBeat})");
Check(lowest <= 130, $"between beats the lamp rests dimmer ({lowest})");
for (var i = 0; i < 100; i++) music.Step(0.05);
Check(!music.MusicDetected && music.Step(0.05) == white, "silence releases beat sync");

// Beat detector: 120 BPM kicks, silence, steady tone.
const double rate = 48_000;
var random = new Random(7);
var kicks = new float[(int)(rate * 4)];
for (var i = 0; i < kicks.Length; i++)
{
    var t = i / rate;
    var noise = (float)(random.NextDouble() * 0.004 - 0.002);
    kicks[i] = (t % 0.5 < 0.08 ? (float)(0.8 * Math.Sin(2 * Math.PI * 60 * t)) : 0) + noise;
}
var beats = new BeatDetector(rate).Process(kicks);
Check(beats.Count is >= 6 and <= 9, $"~8 kicks in 4 s at 120 BPM (got {beats.Count})");
Check(beats.All(b => b is > 0 and <= 1), "beat strengths within 0–1");
Check(new BeatDetector(rate).Process(new float[(int)(rate * 2)]).Count == 0, "silence produces no beats");
var tone = Enumerable.Range(0, (int)(rate * 3)).Select(i => (float)(0.5 * Math.Sin(2 * Math.PI * 60 * i / rate))).ToArray();
Check(new BeatDetector(rate).Process(tone).Count <= 1, "steady tone does not keep producing beats");

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} check(s) failed");
    return 1;
}
Console.WriteLine("PenlightCore self-tests passed");
return 0;
