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
    Check(DominantColor.Find(new[] { solid.Red, solid.Green, solid.Blue, (byte)255 }, 1, 1, 4) == solid, $"solid RGBA {solid}");
    Check(DominantColor.Find(new[] { solid.Blue, solid.Green, solid.Red, (byte)255 }, 1, 1, 4, bgra: true) == solid, $"solid BGRA {solid}");
}

var mixed = DominantColor.Find(new byte[] { 255, 0, 0, 255, 0, 0, 255, 255 }, 2, 1, 8);
Check(mixed is { } m && Math.Max(m.Red, m.Blue) > 200 && m.Green < 16 && !(m.Red > 100 && m.Blue > 100), "mixed red/blue picks a real color");

byte[] padded =
{
    240, 8, 10, 255, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE, 0xEE,
    240, 8, 10, 255, 0, 0, 0, 0, 0xDD, 0xDD, 0xDD, 0xDD,
};
Check(DominantColor.Find(padded, 2, 2, 12) == new Rgb(240, 8, 10), "padded rows and transparent pixels");
Check(DominantColor.Find(new byte[] { 0, 0, 0, 255 }, 2, 1, 8) == null, "malformed buffer");

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} check(s) failed");
    return 1;
}
Console.WriteLine("PenlightCore self-tests passed");
return 0;
