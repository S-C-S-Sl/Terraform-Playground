#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Konfiguriert WinRM so, dass der Terraform-Provider taliesins/hyperv
  per HTTP/NTLM auf localhost zugreifen kann.
  Idempotent. Mit -Revert wird AllowUnencrypted wieder deaktiviert
  (WinRM selbst bleibt aktiv, da es ggf. von der IT genutzt wird).
#>
param(
    [int]   $MaxMemoryPerShellMB = 1024,
    [int]   $MaxTimeoutMs        = 1800000,
    [switch]$Revert
)
$ErrorActionPreference = "Stop"

function Set-WSManValue {
    param([string]$Path, [string]$Name, $Value)
    $current = (Get-WSManInstance -ResourceURI $Path).$Name
    if ("$current" -ne "$Value") {
        try {
            Set-WSManInstance -ResourceURI $Path -ValueSet @{ $Name = $Value } | Out-Null
            Write-Host "$Path/$Name : $current -> $Value"
        } catch {
            throw "Setzen von $Path/$Name fehlgeschlagen (ggf. per Gruppenrichtlinie gesperrt): $_"
        }
    }
}

if ($Revert) {
    Set-WSManValue -Path "winrm/config/service" -Name AllowUnencrypted -Value "false"
    Write-Host "AllowUnencrypted deaktiviert. WinRM bleibt aktiv."
    return
}

# WinRM-Dienst und HTTP-Listener (5985); Firewall wird bewusst nicht angepasst
Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null

Set-WSManValue -Path "winrm/config/service"      -Name AllowUnencrypted    -Value "true"
Set-WSManValue -Path "winrm/config/service/auth" -Name Negotiate           -Value "true"
Set-WSManValue -Path "winrm/config/winrs"        -Name MaxMemoryPerShellMB -Value $MaxMemoryPerShellMB
Set-WSManValue -Path "winrm/config"              -Name MaxTimeoutms        -Value $MaxTimeoutMs

# Prüfung
Test-WSMan localhost | Out-Null
Write-Host "WinRM erreichbar auf localhost:5985"
[pscustomobject]@{
    AllowUnencrypted    = (Get-WSManInstance winrm/config/service).AllowUnencrypted
    Negotiate           = (Get-WSManInstance winrm/config/service/auth).Negotiate
    MaxMemoryPerShellMB = (Get-WSManInstance winrm/config/winrs).MaxMemoryPerShellMB
    MaxTimeoutms        = (Get-WSManInstance winrm/config).MaxTimeoutms
} | Format-List
