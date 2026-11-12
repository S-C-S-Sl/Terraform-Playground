#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][string]$GatewayIp,
    [Parameter(Mandatory)][int]   $PrefixLength,
    [Parameter(Mandatory)][string]$NatPrefix,
    [Parameter(Mandatory)][string]$NatName
)
$ErrorActionPreference = "Stop"
$alias = "vEthernet ($SwitchName)"

# Adapter erscheint nach dem Anlegen des Switches ggf. verzögert
for ($i = 0; $i -lt 30 -and -not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue); $i++) {
    Start-Sleep -Seconds 1
}
if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) {
    throw "Adapter '$alias' nicht gefunden."
}

if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -PrefixLength $PrefixLength | Out-Null
    Write-Host "Gateway-IP $GatewayIp gesetzt"
}

if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
    Write-Host "NAT $NatName für $NatPrefix angelegt"
}
