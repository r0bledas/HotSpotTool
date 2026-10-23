[CmdletBinding()]
param (
    [switch]$Monitor,
    [switch]$BootDelay,
    [switch]$Install,
    [switch]$Uninstall,
    [int]$MaxPeers = 50,
    [switch]$Silent
)

$toolScript = Join-Path $PSScriptRoot "HotspotTool.ps1"
& $toolScript -MaxPeers 50 @PSBoundParameters
