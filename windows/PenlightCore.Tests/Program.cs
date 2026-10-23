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

// LightEngine: same cases as LightEngineTests.swift.
var red = new Rgb(255, 0, 0);
var blue = new Rgb(0, 0, 255);
var engine = new LightEngine(0.6, breathing: false);
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

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} check(s) failed");
    return 1;
}
Console.WriteLine("PenlightCore self-tests passed");
return 0;
