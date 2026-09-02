# mock_bridge.ps1 - Zero-dependency mock live bridge server
# Uses PowerShell + .NET HttpListener WebSocket to simulate the bridge process
# Listens on 127.0.0.1:8899, sends simulated live event JSON periodically
# Usage: powershell -ExecutionPolicy Bypass -File mock_bridge.ps1

param(
    [int]$Port = 8899
)

# ========== Start HttpListener ==========

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

Write-Host "[MockBridge] Mock bridge server started, listening on port $Port" -ForegroundColor Green
Write-Host "[MockBridge] Godot should connect to ws://127.0.0.1:$Port" -ForegroundColor Cyan
Write-Host "[MockBridge] Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

# ========== Global State ==========

$script:clients = New-Object 'System.Collections.Generic.List[System.Net.WebSockets.WebSocket]'
$script:running = $true

# ========== Mock Data ==========

$mockUnames = @("ViewerA", "PasserbyB", "TycoonC", "NewbieD", "BossE", "LurkerF", "SpectatorG", "FanH")
$mockGifts = @(
    @{ name = "SpicyStrip"; num = 1; value = 0.01 },
    @{ name = "Heart"; num = 1; value = 0.1 },
    @{ name = "BKT"; num = 1; value = 5.0 },
    @{ name = "Cheers"; num = 10; value = 10.0 },
    @{ name = "Captain"; num = 1; value = 198.0 }
)
$mockDanmus = @("GoGoGo", "6666", "Haha", "SoStrong", "WhoAmI", "SoHard", "KeepGoing", "Streaming?")

# ========== Broadcast Function ==========

function Send-ToClients([string]$messageJson) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($messageJson)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    
    $dead = New-Object 'System.Collections.Generic.List[System.Net.WebSockets.WebSocket]'
    foreach ($ws in $script:clients) {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None) | Out-Null
            } catch {
                $dead.Add($ws)
            }
        } else {
            $dead.Add($ws)
        }
    }
    foreach ($d in $dead) {
        $script:clients.Remove($d)
    }
}

# ========== Async Accept Connections ==========

$acceptCallback = {
    param($ar)
    if (-not $script:running) { return }
    try {
        $ctx = $listener.EndGetContext($ar)
        if ($script:running) {
            $listener.BeginGetContext($acceptCallback, $null)
        }
        
        if ($ctx.Request.IsWebSocketRequest) {
            $wsCtx = $ctx.AcceptWebSocketAsync("chat").Result
            $script:clients.Add($wsCtx.WebSocket)
            Write-Host "[MockBridge] Godot client connected ($($script:clients.Count) total)" -ForegroundColor Green
        } else {
            $ctx.Response.StatusCode = 400
            $ctx.Response.Close()
        }
    } catch {
        # Ignore on listener shutdown
    }
}

$listener.BeginGetContext($acceptCallback, $null)

Write-Host "[MockBridge] Mock events started:" -ForegroundColor Green
Write-Host "  - Enter: every ~3s -> spawn slime" -ForegroundColor Magenta
Write-Host "  - Danmu: every ~1.5s (no enemy)" -ForegroundColor Gray
Write-Host "  - Gift:  every ~6s -> spawn by value" -ForegroundColor Yellow
Write-Host ""

# ========== Main Loop: Periodic Mock Events ==========

$enterTimer = 0.0
$danmuTimer = 0.0
$giftTimer = 0.0
$enterInterval = 3.0
$danmuInterval = 1.5
$giftInterval = 6.0

try {
    while ($script:running) {
        Start-Sleep -Milliseconds 100
        $now = [Environment]::TickCount / 1000.0
        
        # Enter event
        if ($now - $enterTimer -ge $enterInterval) {
            $enterTimer = $now
            $uname = $mockUnames | Get-Random
            $uid = Get-Random -Minimum 1 -Maximum 999999
            $event = @{
                event = "enter"
                platform = "bilibili"
                uid = "$uid"
                uname = $uname
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            } | ConvertTo-Json -Compress
            Write-Host "[MockBridge] Enter: $uname" -ForegroundColor Magenta
            Send-ToClients $event
        }
        
        # Danmu event
        if ($now - $danmuTimer -ge $danmuInterval) {
            $danmuTimer = $now
            $uname = $mockUnames | Get-Random
            $text = $mockDanmus | Get-Random
            $uid = Get-Random -Minimum 1 -Maximum 999999
            $event = @{
                event = "danmu"
                platform = "bilibili"
                uid = "$uid"
                uname = $uname
                text = $text
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            } | ConvertTo-Json -Compress
            Write-Host "[MockBridge] Danmu: ${uname}: $text" -ForegroundColor Gray
            Send-ToClients $event
        }
        
        # Gift event
        if ($now - $giftTimer -ge $giftInterval) {
            $giftTimer = $now
            $uname = $mockUnames | Get-Random
            $gift = $mockGifts | Get-Random
            $uid = Get-Random -Minimum 1 -Maximum 999999
            $giftId = Get-Random -Minimum 1 -Maximum 100
            $event = @{
                event = "gift"
                platform = "bilibili"
                uid = "$uid"
                uname = $uname
                gift_id = "$giftId"
                gift_name = $gift.name
                num = $gift.num
                value = $gift.value
                coin_type = "gold"
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            } | ConvertTo-Json -Compress
            Write-Host "[MockBridge] Gift: ${uname} sent $($gift.num) x $($gift.name) (Y$($gift.value))" -ForegroundColor Yellow
            Send-ToClients $event
        }
    }
} catch {
    # Ctrl+C interrupt
} finally {
    $script:running = $false
    $listener.Stop()
    Write-Host "`n[MockBridge] Server stopped" -ForegroundColor Red
}
