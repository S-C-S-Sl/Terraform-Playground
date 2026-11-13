# Terraform-Playground – Kubernetes-Lab auf Hyper-V

Lokales Lab, um einen Kubernetes-Cluster auf Hyper-V aufzubauen.
Infrastruktur mit **Terraform** (Provider [`taliesins/hyperv`](https://registry.terraform.io/providers/taliesins/hyperv/latest)),
später Konfiguration mit **Ansible** und Cluster-Inhalte mit **Helm**.

> Status: Netzwerk und erste VM (`cp-1`) laufen, Zugang per SSH-Zertifikat funktioniert. Als Nächstes: Ansible und Kubernetes.

## Struktur

```
.
├── host/                         # Windows-Host (PowerShell)
│   ├── winrm.ps1                 # einmalig: WinRM für den Terraform-Provider einrichten
│   ├── Terraform-SetUserEnv.ps1  # pro Sitzung: Zugangsdaten als TF_VAR_* setzen
│   ├── setup-nat.ps1             # von Terraform aufgerufen: Host-IP + NAT anlegen
│   └── teardown-nat.ps1          # von Terraform aufgerufen: NAT + Host-IP entfernen
├── base-image/                   # Basis-Images bauen (WSL, Bash)
│   └── prepare-image.sh
├── ssh/                          # Zugang zu den VMs (WSL, Bash)
│   └── sign-cert.sh              # pro Sitzung: kurzlebiges SSH-Zertifikat ausstellen
├── ansible/                      # Konfiguration der VMs (WSL)
│   └── inventory/
│       ├── hosts.yml             # von Terraform erzeugt, nicht eingecheckt
│       └── group_vars/all.yml    # Verbindung: Benutzer, Schlüssel, SSH-Optionen
└── terraform/                    # Lab-Ressourcen
    ├── versions.tf
    ├── providers.tf
    ├── variables.tf
    ├── network.tf                # internal Switch + NAT
    ├── nodes.tf                  # VMs: Differencing-Disk, cloud-init-ISO, VM
    ├── nodes.auto.tfvars         # welche VMs (Rolle, IP, CPU, RAM), eingecheckt
    ├── inventory.tf              # erzeugt ansible/inventory/hosts.yml aus nodes
    ├── outputs.tf
    ├── templates/                # cloud-init: user-data, network-config, meta-data
    ├── terraform.tfvars.example  # Vorlage für terraform.tfvars (nicht eingecheckt)
    └── .terraform.lock.hcl       # Provider-Version, gehört ins Repo
```

| Ordner | Läuft wo | Zweck |
|---|---|---|
| `host/` | Windows, PowerShell | Hyper-V-Host vorbereiten |
| `base-image/` | WSL, Bash | Basis-Images bauen |
| `ssh/` | WSL, Bash | Zugang zu den VMs |
| `ansible/` | WSL | Konfiguration der VMs |
| `terraform/` | Windows, Admin-PowerShell | Netz und VMs |

Bash-Skripte werden mit `bash <skript>` aufgerufen, nicht über PowerShell. Die `.gitattributes`
(`* text=auto eol=lf`) sorgt dafür, dass sie auch unter Windows mit LF-Zeilenenden ausgecheckt werden.

## Voraussetzungen

- Windows mit aktiviertem **Hyper-V**
- **Terraform** ≥ 1.5 (`winget install Hashicorp.Terraform`)
- **WSL** (Ubuntu 24.04) mit `qemu-utils`, `curl`, `openssh-client` und **Ansible** (Schritt 9)
- Admin-Rechte auf dem Host
- Mindestens 40–50 GB freier Speicher für Images und VMs
- **WSL im Mirrored-Netzwerkmodus** (siehe unten)

### WSL im Mirrored-Netzwerkmodus

Im Standardmodus (NAT) hängt WSL in einem eigenen Netz (`172.x`) hinter Windows und erreicht das
Lab-Netz `192.168.250.0/24` nicht: `ssh` aus WSL bleibt ohne Meldung hängen. Im Mirrored-Modus teilt
sich WSL die Netzwerkschnittstellen mit Windows und sieht auch `vEthernet (k8s-lab)`.

`C:\Users\<benutzer>\.wslconfig` (ohne Dateiendung; eine bestehende Datei nur ergänzen):

```ini
[wsl2]
networkingMode=mirrored
```

Übernehmen und prüfen:

```powershell
wsl --shutdown
wsl -d Ubuntu-24.04
```

```bash
wslinfo --networking-mode      # mirrored
ip route                       # enthält 192.168.250.0/24
```

- Gilt für **alle** WSL-Distributionen, auch für Docker Desktop. Danach kurz prüfen, ob bestehende Container noch erreichbar sind.
- Voraussetzung ist Windows 11 22H2 oder neuer. Auf Firmenrechnern kann der Modus per Richtlinie festgelegt sein.
- `wsl --shutdown` beendet auch den ssh-agent in WSL. Danach das Zertifikat erneut laden (Schritt 4).

## Einrichtung

### 1. WinRM einrichten (einmalig, Admin-PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File .\host\winrm.ps1
```

Das Skript ist idempotent. Es aktiviert WinRM (HTTP, Port 5985), erlaubt NTLM und unverschlüsselte Nachrichten
und erhöht Speicher- und Timeout-Limits. Die Firewall wird bewusst nicht angepasst.

> **Sicherheit:** `AllowUnencrypted = true` gilt für alle WinRM-Verbindungen, nicht nur für `localhost`.
> Nach dem Arbeiten mit dem Lab zurücksetzen:
> `powershell -ExecutionPolicy Bypass -File .\host\winrm.ps1 -Revert`
>
> Auf Firmenrechnern können diese Einstellungen per Gruppenrichtlinie gesperrt sein.

### 2. Basis-Image bauen (einmalig, WSL)

```bash
sudo apt install -y qemu-utils curl
bash base-image/prepare-image.sh ubuntu-2404 \
  https://cloud-images.ubuntu.com/releases/noble/release-<YYYYMMDD>/ubuntu-24.04-server-cloudimg-amd64.img
```

`<YYYYMMDD>` durch den aktuellen Ordner unter `https://cloud-images.ubuntu.com/releases/noble/` ersetzen.
Ältere datierte Ordner werden nach einigen Monaten entfernt.

Das Skript lädt das Ubuntu-Cloud-Image, prüft die Prüfsumme, vergrößert die virtuelle Disk auf 20 GB
und konvertiert sie nach VHDX. Standardziel ist `/mnt/d/Hyper-V/images`, ein anderes Ziel als drittes Argument.

Danach auf dem Host prüfen und schreibschützen. Von dieser Datei werden alle VM-Disks abgeleitet,
sie darf nie verändert werden:

```powershell
$img = "D:\Hyper-V\images\ubuntu-2404-base.vhdx"
Test-VHD $img
Set-ItemProperty $img -Name IsReadOnly -Value $true
```

### 3. SSH-CA und Benutzerschlüssel anlegen (einmalig, WSL)

Der Zugang zu den VMs läuft über SSH-Zertifikate statt über einzelne Schlüssel in `authorized_keys`:
Die VMs vertrauen einer eigenen CA, und die CA stellt kurzlebige Zertifikate für den Benutzerschlüssel aus.

```bash
mkdir -p ~/.ssh-ca && chmod 700 ~/.ssh-ca
ssh-keygen -t ed25519 -C "k8s-lab user CA"   -f ~/.ssh-ca/k8s_lab_user_ca     # Aussteller
ssh-keygen -t ed25519 -C "sebastian@k8s-lab" -f ~/.ssh/id_ed25519_k8s_lab     # Login-Identität
```

| Schlüssel | Rolle | Wo bekannt |
|---|---|---|
| `~/.ssh-ca/k8s_lab_user_ca` | signiert Benutzerschlüssel | öffentlicher Teil per cloud-init auf allen VMs (`TrustedUserCAKeys`) |
| `~/.ssh/id_ed25519_k8s_lab` | Anmeldung bei den VMs | nur im Zertifikat |

> Der private CA-Schlüssel gehört weder ins Repo noch in den Terraform-State.
> Wer ihn besitzt, kann sich Zugang zu allen VMs ausstellen. Immer mit Passphrase anlegen.

### 4. Zertifikat ausstellen (pro Arbeitssitzung, WSL)

```bash
cd /mnt/c/<pfad-zum-repo>
eval "$(ssh-agent -s)"          # optional, für -a
bash ssh/sign-cert.sh -a
```

Ergebnis ist `~/.ssh/id_ed25519_k8s_lab-cert.pub`, standardmäßig **8 Stunden** gültig (ab 5 Minuten in der
Vergangenheit, um Uhrzeitabweichungen der VMs abzufangen). Geprüft wird nur beim Verbindungsaufbau,
laufende Sitzungen brechen bei Ablauf nicht ab.

| Option | Umgebungsvariable | Standard |
|---|---|---|
| `-c <name\|pfad>` | `K8S_LAB_CA_KEY` | `k8s_lab_user_ca` (in `K8S_LAB_CA_DIR`, Standard `~/.ssh-ca`) |
| `-k <pfad>` | `K8S_LAB_USER_KEY` | `~/.ssh/id_ed25519_k8s_lab` |
| `-n <liste>` | `K8S_LAB_PRINCIPALS` | `ubuntu` |
| `-V <dauer>` | `K8S_LAB_VALIDITY` | `8h` |
| `-I <kennung>` | `K8S_LAB_IDENTITY` | `<user>@k8s-lab` |
| `-a` | | Schlüssel + Zertifikat mit gleicher Lebensdauer in den ssh-agent |

Zertifikat prüfen: `ssh-keygen -L -f ~/.ssh/id_ed25519_k8s_lab-cert.pub`

### 5. Zugangsdaten für Terraform setzen (pro PowerShell-Sitzung)

```powershell
.\host\Terraform-SetUserEnv.ps1
```

Direkt aufrufen, **nicht** über `powershell -File`, sonst gehen die Variablen mit dem Kindprozess verloren.
Die Zugangsdaten werden nicht gespeichert und verschwinden mit dem Schließen des Fensters.

### 6. Variablen festlegen (einmalig)

```powershell
Copy-Item terraform\terraform.tfvars.example terraform\terraform.tfvars
```

`terraform.tfvars` ist per `.gitignore` ausgeschlossen. Das Repo ist öffentlich, interne Adressen und
Hashes gehören deshalb nur in diese Datei.

| Variable | Pflicht | Inhalt |
|---|---|---|
| `dns_servers` | ja | DNS-Server des Hosts: `Get-DnsClientServerAddress -AddressFamily IPv4` |
| `ssh_user_ca_public_key` | ja | Inhalt von `~/.ssh-ca/k8s_lab_user_ca.pub` (WSL: `cat ~/.ssh-ca/k8s_lab_user_ca.pub`) |
| `base_image_path` | nein | Standard `D:\Hyper-V\images\ubuntu-2404-base.vhdx` |
| `vm_root` | nein | Standard `D:\Hyper-V\VMs`, pro VM ein Unterordner |
| `console_password_hash` | nein | Notfall-Login an der Hyper-V-Konsole, siehe unten |

Die VMs selbst stehen in `terraform/nodes.auto.tfvars` (wird automatisch geladen und ist eingecheckt):

```hcl
nodes = {
  cp-1     = { role = "control_plane", ip = "192.168.250.11", memory_gb = 4 }
  worker-1 = { role = "worker",        ip = "192.168.250.21" }   # cpus/memory_gb optional, Standard 2/2
}
```

Konvention: `cp-<n>` (Control Plane) ab `.11`, `worker-<n>` ab `.21`. Ungültige Namen, Rollen,
doppelte oder netzfremde IPs fallen beim `terraform plan` auf.

#### Konsolen-Passwort (optional, für den ersten Test empfohlen)

Der normale Zugang zu den VMs läuft ausschließlich per SSH-Zertifikat. Scheitert beim ersten Boot
etwas (cloud-init, Netzwerk, sshd), gibt es sonst keinen Weg in die VM, denn das Ubuntu-Cloud-Image
hat kein Standardpasswort. Mit `console_password_hash` kann sich der Benutzer `ubuntu` an der
**Hyper-V-Konsole** anmelden (Hyper-V-Manager → *Verbinden*).

Hash erzeugen (WSL):

```bash
sudo apt install -y whois     # enthält mkpasswd
mkpasswd -m sha-512
```

Den Hash (beginnt mit `$6$`) in `terraform.tfvars` eintragen:

```hcl
console_password_hash = "$6$..."
```

- SSH-Login per Passwort bleibt abgeschaltet (`ssh_pwauth: false`), das Passwort gilt nur an der Konsole.
- Der Hash landet in der Seed-ISO, in `terraform/.build/` und im State. Nur ein eigenes Lab-Passwort verwenden.
- Sobald der Zugang per Zertifikat zuverlässig funktioniert, die Zeile wieder entfernen.
  Der Benutzer ist dann für Passwort-Logins gesperrt.

Hilfreich an der Konsole bei Problemen:

```bash
cloud-init status --long
ip addr
sudo journalctl -u ssh
```

### 7. Terraform ausführen (Admin-PowerShell)

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

Admin-Rechte sind nötig, weil Terraform für das NAT `host/setup-nat.ps1` aufruft.
Aus einem normalen Terminal (z. B. in WebStorm) öffnet dieser Befehl ein Admin-Fenster im selben Ordner:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit', '-Command', "Set-Location '$PWD'"
```

Im neuen Fenster die Zugangsdaten erneut setzen (Schritt 5), da es ein eigener Prozess ist.

### 8. Erste Anmeldung (WSL)

Nach dem `apply` ein bis zwei Minuten warten, bis cloud-init durch ist. Das Zertifikat muss gültig sein (Schritt 4).

**In der Ubuntu-WSL ausführen, nicht unter Windows.** Schlüssel, Zertifikat und ssh-agent liegen nur dort.
Bei mehreren Distributionen gezielt öffnen: `wsl -d Ubuntu-24.04`.

```bash
ssh -i ~/.ssh/id_ed25519_k8s_lab ubuntu@192.168.250.11
cloud-init status --long          # status: done
ping -c 2 8.8.8.8                 # NAT
getent hosts archive.ubuntu.com   # DNS
```

### 9. Ansible einrichten (einmalig, WSL)

Installation per `pipx`, damit Ansible aktuell ist und nicht mit den Python-Paketen des Systems kollidiert:

```bash
sudo apt update && sudo apt install -y pipx
pipx install --include-deps ansible
pipx ensurepath          # danach neues Terminal öffnen
ansible --version
```

`ANSIBLE_INVENTORY` dauerhaft setzen (Pfad zum Repo anpassen):

```bash
echo 'export ANSIBLE_INVENTORY=/mnt/c/<pfad-zum-repo>/ansible/inventory/hosts.yml' >> ~/.bashrc
source ~/.bashrc
```

Die gesamte Konfiguration ist YAML, eine `ansible.cfg` (INI-Format) gibt es bewusst nicht:

| Datei | Inhalt |
|---|---|
| `inventory/hosts.yml` | Hosts und Gruppen, erzeugt von Terraform (`terraform/inventory.tf`) aus `nodes.auto.tfvars` |
| `inventory/group_vars/all.yml` | Verbindung für alle VMs: Benutzer `ubuntu`, Schlüssel `~/.ssh/id_ed25519_k8s_lab`, SSH-Optionen |

- `group_vars/` neben dem Inventory lädt Ansible automatisch.
- Das Zertifikat neben dem Schlüssel verwendet OpenSSH automatisch mit.
- Unbekannte Host-Schlüssel werden beim ersten Kontakt übernommen (`StrictHostKeyChecking=accept-new`), geänderte aber abgelehnt.
- Die Gruppen im Inventory ergeben sich aus `role`: `control_plane` und `workers`. Nach jeder Änderung an
  `nodes.auto.tfvars` einmal `terraform apply`, dann ist das Inventory aktuell.

Warum keine `ansible.cfg`: Verzeichnisse unter `/mnt/c` gelten für WSL als *world-writable*, und Ansible
ignoriert eine `ansible.cfg` im aktuellen Ordner dann aus Sicherheitsgründen. Ohne Datei entfällt das Problem.
Was sich nur in einer `ansible.cfg` einstellen lässt, wird bei Bedarf über Umgebungsvariablen gesetzt.

### 10. Verbindung testen (WSL)

Zertifikat gültig (Schritt 4), dann:

```bash
ansible-inventory --graph
ansible-inventory --host cp-1                               # zeigt die Variablen aus group_vars
ansible all -m ping                                         # cp-1 | SUCCESS => "ping": "pong"
ansible all -m setup -a 'filter=ansible_distribution*'
```

## Abbau

```powershell
cd terraform
terraform destroy
```

Entfernt Switch, Host-IP und NAT. Das Basis-Image bleibt erhalten.

## Netzwerk

| | |
|---|---|
| Switch | `k8s-lab` (Internal) |
| Subnetz | `192.168.250.0/24` |
| Gateway (Host) | `192.168.250.1` |
| NAT | `k8s-lab-nat` |
| Nodes | ab `192.168.250.11` (statisch per cloud-init) |
| DNS der VMs | die DNS-Server des Hosts (`Get-DnsClientServerAddress`), per Variable |

Der internal Switch hat keine Verbindung zur physischen Netzwerkkarte. Über das NAT erreichen die VMs
das Internet, aber auch das Netz, in dem der Host hängt (z. B. ein Firmennetz).

## Fehlerbehebung

| Symptom | Ursache / Lösung |
|---|---|
| `dial tcp 127.0.0.1:5986 ... refused` | Provider-Block wird nicht gelesen (5986/HTTPS sind die Standardwerte). Dateiendungen und Arbeitsverzeichnis prüfen. |
| `http response error: 401` | Anmeldung abgelehnt. Konto muss lokaler Admin sein; `localhost` statt `127.0.0.1` verwenden. |
| `Input/output error` beim Schreiben nach `/mnt/<laufwerk>` | Meist zu wenig Speicher auf dem Ziel. Alternativ nach `~/images` schreiben und unter Windows mit `Copy-Item` von `\\wsl.localhost\...` holen. |
| `$'\r': command not found` | Shell-Skript mit CRLF ausgecheckt. `.gitattributes` mit `* text=auto eol=lf` anlegen und `git add --renormalize .` ausführen. |
| `a resource with the ID "k8s-lab" already exists` | Switch existiert, ist aber nicht im State (z. B. nach Wechsel des Arbeitsordners). `terraform import hyperv_network_switch.lab k8s-lab` |
| `Rechte von ... zu offen` (sign-cert.sh) | `chmod 600 ~/.ssh-ca/k8s_lab_user_ca` |
| `ssh` aus WSL hängt ohne Meldung | WSL läuft im NAT-Modus (`ip route` zeigt nur ein `172.x`-Netz). Mirrored-Modus aktivieren, siehe Voraussetzungen. |
| `Identity file ... not accessible` und `Permission denied (publickey)` | SSH wurde unter Windows gestartet. Schlüssel und Zertifikat liegen in der Ubuntu-WSL. |
| `ssh-keygen: command not found` oder Prompt `root@...` | Falsche WSL-Distribution (Standard ist evtl. eine andere). `wsl -l -v` prüfen, `wsl -d Ubuntu-24.04` öffnen. |
| `No inventory was parsed, only implicit localhost is available` | `ANSIBLE_INVENTORY` ist nicht gesetzt (Schritt 9) oder `terraform apply` hat das Inventory noch nicht erzeugt. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM wurde neu gebaut und hat einen neuen Host-Schlüssel. Alten Eintrag entfernen: `ssh-keygen -R 192.168.250.11` |
| VM nicht per SSH erreichbar | An der Hyper-V-Konsole anmelden (erfordert `console_password_hash`) und `cloud-init status --long` prüfen. |
| SSH: `Permission denied (publickey)` | Zertifikat abgelaufen oder falscher Principal: `ssh-keygen -L -f ~/.ssh/id_ed25519_k8s_lab-cert.pub` prüfen, ggf. neu signieren. |

## Ausblick

- [x] cloud-init Seed-ISO und erste VM (Gen2, Differencing-Disk), öffentlicher CA-Schlüssel per cloud-init
- [x] VMs per `for_each` aus `nodes.auto.tfvars`
- [ ] `wait_for_ips = false` an der Netzwerkkarte (ohne KVP-Daemon wartet der Provider sonst 5 min pro VM)
- [ ] Konsolen-Passwort wieder entfernen, sobald der Zertifikats-Zugang sich bewährt hat
- [ ] Ablageort des Basis-Images außerhalb des Repos
- [ ] Host-Zertifikate (VMs weisen sich per CA aus, kein Fingerprint-Wechsel nach Neuaufbau)
- [ ] Ansible: Grundgerüst, Inventory aus Terraform
- [ ] Ansible: containerd, kubeadm, Cluster-Aufbau
- [ ] Helm: Cilium als CNI, danach Argo CD
- [ ] RHEL-Image (Developer Subscription) als zweite Distribution
