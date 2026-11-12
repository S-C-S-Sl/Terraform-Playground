$cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Hyper-V / WinRM"
$env:TF_VAR_hyperv_user     = $cred.UserName
$env:TF_VAR_hyperv_password = $cred.GetNetworkCredential().Password
