<#
.SYNOPSIS
    Baut die komplette lokale Kubernetes-Umgebung (Hyper-V) auf oder ab - in den Schritten aus der README ("Cluster neu aufbauen").

.DESCRIPTION
    Läuft in einer Admin-PowerShell (NAT-Skript von Terraform braucht Admin-Rechte).
    Terraform läuft unter Windows, alles andere (Ansible, kubectl, Helm) in der WSL-Distribution.
    Nach jedem Schritt wird nachgefragt: weiter, Schritt wiederholen oder abbrechen.

.PARAMETER Action
    up   = aufbauen (Standard)
    down = abbauen (terraform destroy)

.PARAMETER From
    Aufbau ab diesem Schritt fortsetzen (Nummer aus der Übersicht), z. B. nach einem Abbruch.

.PARAMETER NoConfirm
    Ohne Rückfragen durchlaufen (Terraform fragt bei apply/destroy trotzdem selbst nach).

.PARAMETER Distro
    WSL-Distribution mit Ansible, kubectl, Helm und den SSH-Schlüsseln.

.EXAMPLE
    .\host\build-local-k8s.ps1                 # aufbauen, mit Rückfrage nach jedem Schritt
    .\host\build-local-k8s.ps1 -From 5         # ab Schritt 5 fortsetzen
    .\host\build-local-k8s.ps1 down            # abbauen
#>
[CmdletBinding()]
param(
    [ValidateSet('up', 'down')]
    [string]$Action = 'up',
    [int]$From = 1,
    [switch]$NoConfirm,
    [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TerraformDir = Join-Path $RepoRoot 'terraform\hyper-v'

# --- Hilfsfunktionen -----------------------------------------------------------------------

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

# Führt Bash-Befehle in der WSL-Distribution aus, im Repo-Root.
# Das Skript geht als Datei nach WSL (nicht als Argument): so gibt es keine Probleme mit Anführungszeichen,
# und Eingaben (z. B. Passphrasen) laufen weiter über das Terminal.
# Jeder Aufruf ist eine eigene Shell: Umgebung (kubeconfig, ssh-agent, Inventory) wird hier gesetzt.
# Der ssh-agent läuft über einen festen Socket weiter, solange die WSL-Distribution läuft.
function Invoke-Wsl([string]$Script) {
    $prelude = @'
set -euo pipefail
export KUBECONFIG="$HOME/.kube/k8s-lab.conf"
export SSH_AUTH_SOCK="$HOME/.ssh/lab-agent.sock"
export INV=ansible/inventory/hosts.yml
'@
    $full = ($prelude + "`n" + $Script + "`n") -replace "`r", ''
    $file = Join-Path ([IO.Path]::GetTempPath()) "build-local-k8s-step.sh"
    [IO.File]::WriteAllText($file, $full, (New-Object Text.UTF8Encoding($false)))
    $wslFile = (& wsl.exe -d $Distro -- wslpath -u ($file -replace '\\', '/')).Trim()
    & wsl.exe -d $Distro --cd $RepoRoot -- bash -l $wslFile
    $exitCode = $LASTEXITCODE
    Remove-Item $file -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { throw "WSL-Befehl endete mit Exit-Code $exitCode" }
}

function Invoke-Terraform([string[]]$Arguments) {
    & terraform "-chdir=$TerraformDir" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "terraform $($Arguments -join ' ') endete mit Exit-Code $LASTEXITCODE" }
}

# Rückfrage nach einem Schritt: (W)eiter, (R)epeat = wiederholen, (A)bbrechen
function Read-Next([string]$Question) {
    if ($NoConfirm) { return 'W' }
    while ($true) {
        $answer = (Read-Host "$Question  [W]eiter / [R] wiederholen / [A]bbrechen").Trim().ToUpper()
        if ($answer -eq '') { $answer = 'W' }
        if ($answer -in 'W', 'R', 'A') { return $answer }
    }
}

# Führt die Schritte nacheinander aus: nach jedem Schritt (und nach jedem Fehler) Rückfrage.
function Invoke-Steps($Steps, [int]$Start) {
    for ($i = $Start - 1; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        Write-Step ("Schritt {0}/{1}: {2}" -f ($i + 1), $Steps.Count, $step.Name)
        try {
            & $step.Run
            $question = "Schritt $($i + 1) abgeschlossen."
        }
        catch {
            Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
            $question = "Schritt $($i + 1) fehlgeschlagen."
            if ($NoConfirm) { throw }
        }
        switch (Read-Next $question) {
            'R' { $i-- }
            'A' {
                Write-Host ''
                Write-Host "Abgebrochen. Fortsetzen mit: .\host\build-local-k8s.ps1 -From $($i + 2)  (bzw. -From $($i + 1) zum Wiederholen)" -ForegroundColor Yellow
                exit 1
            }
        }
    }
}

# --- Voraussetzungen -------------------------------------------------------------------------

function Test-Prerequisites {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Bitte in einer Admin-PowerShell ausführen (Terraform legt NAT an bzw. entfernt es).' }
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { throw 'terraform nicht gefunden.' }
    if (-not (Test-Path (Join-Path $TerraformDir 'terraform.tfvars'))) { throw 'terraform\hyper-v\terraform.tfvars fehlt (siehe terraform.tfvars.example).' }
    $distros = (& wsl.exe -l -q) -replace "`0", '' | Where-Object { $_ }
    if ($distros -notcontains $Distro) { throw "WSL-Distribution '$Distro' nicht gefunden." }
    if ((Get-Service WinRM).Status -ne 'Running') { throw 'Dienst WinRM läuft nicht (siehe host\winrm.ps1).' }

    # Zugangsdaten für den Hyper-V-Provider (WinRM), nur wenn noch nicht in dieser Sitzung gesetzt
    if (-not $env:TF_VAR_hyperv_user -or -not $env:TF_VAR_hyperv_password) {
        . (Join-Path $PSScriptRoot 'Terraform-SetUserEnv.ps1')
    }
    Write-Host "Repo: $RepoRoot"
    Write-Host "WSL:  $Distro"
    Write-Host "Hyper-V-Benutzer: $env:TF_VAR_hyperv_user"
}

# --- Aufbau -----------------------------------------------------------------------------------

$UpSteps = @(
    @{ Name = 'Voraussetzungen prüfen';
    Run  = { Test-Prerequisites } }

    @{ Name = 'Infrastruktur: terraform apply (VMs, Netz, NAT, Disks)';
    # apply fragt selbst nach ("yes"); plan -detailed-exitcode bricht ab, falls danach noch Änderungen offen sind
    Run  = { Invoke-Terraform @('init', '-input=false'); Invoke-Terraform @('apply'); Invoke-Terraform @('plan', '-detailed-exitcode') } }

    @{ Name = 'Zugang: alte Host-Schlüssel entfernen, ssh-agent, SSH-Zertifikat, warten auf cloud-init';
    Run  = { Invoke-Wsl @'
for ip in 192.168.250.11 192.168.250.12 192.168.250.13 192.168.250.20; do ssh-keygen -R "$ip" >/dev/null 2>&1 || true; done
if ! ssh-add -l >/dev/null 2>&1; then
  rm -f "$SSH_AUTH_SOCK"
  eval "$(ssh-agent -a "$SSH_AUTH_SOCK")" >/dev/null
fi
bash ssh/sign-cert.sh -a
echo "Warte auf die VMs (cloud-init) ..."
for i in $(seq 1 30); do
  if ansible -i "$INV" all -m ping -o >/dev/null 2>&1; then break; fi
  sleep 10
done
ansible -i "$INV" all -m ping -o
'@ } }

    @{ Name = 'NFS-Server (nfs-1)';
    Run  = { Invoke-Wsl 'ansible-playbook -i "$INV" ansible/nfs-server.yml' } }

    @{ Name = 'Kubernetes-Knoten vorbereiten (prepare, containerd, Kubernetes-Pakete)';
    Run  = { Invoke-Wsl @'
ansible-playbook -i "$INV" ansible/prepare.yml
ansible-playbook -i "$INV" ansible/kubernetes.yml
'@ } }

    @{ Name = 'Control Plane (kubeadm init, kubeconfig nach WSL)';
    Run  = { Invoke-Wsl 'ansible-playbook -i "$INV" ansible/control-plane.yml' } }

    @{ Name = 'Pod-Netzwerk: Cilium mit Hubble und IP-Pool';
    Run  = { Invoke-Wsl 'bash platform/cilium/install.sh' } }

    @{ Name = 'Worker beitreten lassen';
    Run  = { Invoke-Wsl @'
ansible-playbook -i "$INV" ansible/workers.yml
kubectl get nodes -o wide
'@ } }

    @{ Name = 'Gateway: Envoy Gateway und Gateway "lab"';
    Run  = { Invoke-Wsl @'
bash platform/envoy-gateway/install.sh
kubectl apply -f platform/gateway/gateway.yaml
kubectl -n gateway wait --for=condition=Programmed gateway/lab --timeout=5m
kubectl -n gateway get gateway lab
'@ } }

    @{ Name = 'RabbitMQ';
    Run  = { Invoke-Wsl 'bash platform/rabbitmq/install.sh' } }

    @{ Name = 'Speicher (NFS-CSI) und MongoDB';
    Run  = { Invoke-Wsl @'
bash platform/nfs-csi/install.sh
bash platform/mongodb/install.sh
'@ } }

    @{ Name = 'Argo CD und Produkt "shop"';
    Run  = { Invoke-Wsl @'
bash platform/argocd/install.sh
bash platform/registry/ghcr-pull-secret.sh
kubectl apply -f platform/argocd/apps/shop.yaml
echo "Warte auf die Application shop ..."
for i in $(seq 1 30); do
  status=$(kubectl -n argocd get application shop -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  [ "$status" = "Synced/Healthy" ] && break
  sleep 10
done
kubectl -n argocd get application shop
'@ } }

    @{ Name = 'Prüfen und Zugangsdaten anzeigen';
    Run  = { Invoke-Wsl @'
echo "--- Pods, die nicht laufen (nur Kopfzeile = alles gut):"
kubectl get pods -A | grep -v -E "Running|Completed" || true
echo "--- Gateway:"; kubectl -n gateway get gateway lab
echo "--- Produkt:"; curl -s -o /dev/null -w "GET /api/catalog/v1/products -> %{http_code}\n" \
  --resolve shop.k8s-lab:80:192.168.250.200 http://shop.k8s-lab/api/catalog/v1/products
echo
echo "RabbitMQ (admin):  $(kubectl -n rabbitmq get secret rabbitmq -o jsonpath='{.data.password}' | base64 -d)"
echo "Argo CD (admin):   $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "MongoDB (root):    $(kubectl -n mongodb get secret mongodb -o jsonpath='{.data.root-password}' | base64 -d)"
'@ } }
)

# --- Abbau ------------------------------------------------------------------------------------

$DownSteps = @(
    @{ Name = 'Voraussetzungen prüfen';
    Run  = { Test-Prerequisites } }

    @{ Name = 'Infrastruktur: terraform destroy (VMs, Disks inkl. NFS-Daten, Netz, NAT)';
    Run  = { Invoke-Terraform @('destroy'); Invoke-Terraform @('state', 'list') } }

    @{ Name = 'Aufräumen in WSL (Host-Schlüssel der VMs)';
    Run  = { Invoke-Wsl @'
for ip in 192.168.250.11 192.168.250.12 192.168.250.13 192.168.250.20; do ssh-keygen -R "$ip" >/dev/null 2>&1 || true; done
echo "kubeconfig ~/.kube/k8s-lab.conf bleibt liegen und wird beim nächsten Aufbau überschrieben."
'@ } }
)

# --- Ablauf -----------------------------------------------------------------------------------

$steps = if ($Action -eq 'up') { $UpSteps } else { $DownSteps }
Write-Host ("Lokale k8s-Umgebung, {0}: {1} Schritte" -f $(if ($Action -eq 'up') { 'Aufbau' } else { 'Abbau' }), $steps.Count) -ForegroundColor Cyan
for ($i = 0; $i -lt $steps.Count; $i++) {
    $marker = if ($i + 1 -lt $From) { '(übersprungen)' } else { '' }
    Write-Host ("  {0,2}. {1} {2}" -f ($i + 1), $steps[$i].Name, $marker)
}
if ($From -lt 1 -or $From -gt $steps.Count) { throw "-From muss zwischen 1 und $($steps.Count) liegen." }

# Ab einem späteren Schritt: Voraussetzungen (inkl. Zugangsdaten) trotzdem prüfen
if ($From -gt 1) { Test-Prerequisites }

Invoke-Steps $steps $From
Write-Host ''
Write-Host ("Fertig: {0}." -f $(if ($Action -eq 'up') { 'Umgebung aufgebaut' } else { 'Umgebung abgebaut' })) -ForegroundColor Green
