#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][string]$GatewayIp,
    [Parameter(Mandatory)][string]$NatName
)
$ErrorActionPreference = "Stop"
$alias = "vEthernet ($SwitchName)"

if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
    Remove-NetNat -Name $NatName -Confirm:$false
    Write-Host "NAT $NatName entfernt"
}

if (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -ErrorAction SilentlyContinue) {
    Remove-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -Confirm:$false
    Write-Host "Gateway-IP $GatewayIp entfernt"
}
