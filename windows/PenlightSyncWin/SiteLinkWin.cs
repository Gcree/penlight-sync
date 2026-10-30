using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using PenlightSync.Core;

namespace PenlightSync.Win;

internal sealed class SiteLinkWin : IDisposable
{
    private const int Port = 51730;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private WebSocket? _activeSocket;
    private readonly object _lock = new();
    private string _lampStatus = "idle";

    public bool PortInUse { get; private set; }
    public Action<SiteState, DateTime>? OnStateUpdate { get; set; }
    public Action? OnStop { get; set; }

    public void SetLampStatus(string status)
    {
        lock (_lock)
        {
            _lampStatus = status;
            if (_activeSocket is { State: WebSocketState.Open } socket)
            {
                _ = SendHelloAsync(socket, status, CancellationToken.None);
            }
        }
    }

    public void Start()
    {
        if (_listener != null) return;
        PortInUse = false;
        try
        {
            _listener = new TcpListener(IPAddress.Loopback, Port);
            _listener.Start();
        }
        catch (SocketException)
        {
            PortInUse = true;
            _listener = null;
            return;
        }

        _cts = new CancellationTokenSource();
        _listenTask = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts = null;
        try
        {
            _listener?.Stop();
        }
        catch { }
        _listener = null;

        lock (_lock)
        {
            if (_activeSocket != null)
            {
                try { _activeSocket.Dispose(); } catch { }
                _activeSocket = null;
            }
        }
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener != null)
        {
            try
            {
                var client = await _listener.AcceptTcpClientAsync(ct);
                _ = Task.Run(() => HandleClientAsync(client, ct), ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception)
            {
                if (ct.IsCancellationRequested) break;
            }
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        using (client)
        await using (var stream = client.GetStream())
        {
            // Read HTTP upgrade request
            var buffer = new byte[4096];
            var bytesRead = 0;
            while (bytesRead < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(bytesRead, buffer.Length - bytesRead), ct);
                if (read == 0) return;
                bytesRead += read;
                if (Encoding.ASCII.GetString(buffer, 0, bytesRead).Contains("\r\n\r\n"))
                    break;
            }

            var requestText = Encoding.ASCII.GetString(buffer, 0, bytesRead);
            var lines = requestText.Split("\r\n");
            if (lines.Length == 0 || !lines[0].StartsWith("GET /ado", StringComparison.OrdinalIgnoreCase))
            {
                await SendHttpErrorAsync(stream, 400, "Bad Request");
                return;
            }

            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 1; i < lines.Length; i++)
            {
                var idx = lines[i].IndexOf(':');
                if (idx > 0)
                {
                    headers[lines[i][..idx].Trim()] = lines[i][(idx + 1)..].Trim();
                }
            }

            // Check Origin
            if (!headers.TryGetValue("Origin", out var origin) || !SiteLinkParser.IsAllowedOrigin(origin))
            {
                await SendHttpErrorAsync(stream, 400, "Bad Request");
                return;
            }

            // Check WebSocket headers
            if (!headers.TryGetValue("Sec-WebSocket-Key", out var secKey) || string.IsNullOrWhiteSpace(secKey))
            {
                await SendHttpErrorAsync(stream, 400, "Bad Request");
                return;
            }

            // Perform handshake
            var acceptKey = Convert.ToBase64String(SHA1.HashData(Encoding.UTF8.GetBytes(secKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            var response =
                "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                $"Sec-WebSocket-Accept: {acceptKey}\r\n\r\n";
            var responseBytes = Encoding.ASCII.GetBytes(response);
            await stream.WriteAsync(responseBytes, ct);

            // Wrap stream in WebSocket
            using var webSocket = WebSocket.CreateFromStream(stream, isServer: true, subProtocol: null, keepAliveInterval: TimeSpan.FromSeconds(30));

            lock (_lock)
            {
                if (_activeSocket != null)
                {
                    try { _activeSocket.Dispose(); } catch { }
                }
                _activeSocket = webSocket;
            }

            // Send initial hello
            string statusToSend;
            lock (_lock) { statusToSend = _lampStatus; }
            await SendHelloAsync(webSocket, statusToSend, ct);

            // Receive loop
            var msgBuffer = new byte[SiteLinkParser.MaxMessageSize + 512];
            while (!ct.IsCancellationRequested && webSocket.State == WebSocketState.Open)
            {
                try
                {
                    var result = await webSocket.ReceiveAsync(msgBuffer, ct);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        await webSocket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closing", ct);
                        break;
                    }
                    if (result.MessageType == WebSocketMessageType.Text && result.EndOfMessage)
                    {
                        var text = Encoding.UTF8.GetString(msgBuffer, 0, result.Count);
                        if (SiteLinkParser.IsStopMessage(text))
                        {
                            OnStop?.Invoke();
                        }
                        else if (SiteLinkParser.ParseState(text) is { } state)
                        {
                            OnStateUpdate?.Invoke(state, DateTime.UtcNow);
                        }
                    }
                }
                catch
                {
                    break;
                }
            }

            lock (_lock)
            {
                if (ReferenceEquals(_activeSocket, webSocket))
                {
                    _activeSocket = null;
                }
            }
        }
    }

    private static async Task SendHelloAsync(WebSocket ws, string lampStatus, CancellationToken ct)
    {
        try
        {
            var json = $"{{\"v\":1,\"type\":\"hello\",\"app\":\"PenlightSync\",\"version\":\"1.7.1\",\"lamp\":\"{lampStatus}\"}}";
            var bytes = Encoding.UTF8.GetBytes(json);
            await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
        }
        catch { }
    }

    private static async Task SendHttpErrorAsync(NetworkStream stream, int code, string status)
    {
        try
        {
            var msg = $"HTTP/1.1 {code} {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(msg));
        }
        catch { }
    }

    public void Dispose()
    {
        Stop();
    }
}
