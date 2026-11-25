# Terraform-Playground – Kubernetes-Lab auf Hyper-V

Lokales Lab, um einen Kubernetes-Cluster auf Hyper-V aufzubauen.
Infrastruktur mit **Terraform** (Provider [`taliesins/hyperv`](https://registry.terraform.io/providers/taliesins/hyperv/latest)),
später Konfiguration mit **Ansible** und Cluster-Inhalte mit **Helm**.

> Status: Cluster mit drei Knoten (`cp-1`, `worker-1`, `worker-2`; Kubernetes 1.37, Cilium 1.20 mit Hubble),
> Envoy Gateway unter `192.168.250.200`, RabbitMQ 4.4, MongoDB 8.3 (auf NFS) und Argo CD laufen; das Produkt `shop`
> wird von Argo CD ausgerollt. Der Neuaufbau in einem Durchgang ist getestet.

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
├── tools/                        # Hilfsskripte für die WSL-Arbeitsumgebung
│   ├── install-helm.sh           # Helm installieren/aktualisieren
│   └── install-k9s.sh            # k9s installieren/aktualisieren
├── platform/                     # Cluster-Inhalte per Helm (WSL)
│   ├── cilium/
│   │   ├── values.yaml           # CNI: Abweichungen von den Chart-Standardwerten
│   │   ├── lb-ippool.yaml        # Pool für LoadBalancer-IPs (192.168.250.200-207)
│   │   └── install.sh            # Chart-Version + Installation/Update + Pool
│   ├── envoy-gateway/
│   │   ├── values.yaml           # Gateway-API-Controller
│   │   └── install.sh
│   ├── gateway/gateway.yaml      # zentrales Gateway "lab" mit fester IP
│   ├── rabbitmq/
│   │   ├── chart/                # eigenes Helm-Chart: ein Broker, ohne Persistenz
│   │   └── install.sh
│   ├── argocd/                   # Argo CD (GitOps) + Applications unter apps/
│   │   ├── values.yaml
│   │   ├── install.sh
│   │   └── apps/shop.yaml
│   ├── nfs-csi/                  # NFS-CSI-Treiber + StorageClass "standard" (dynamisch)
│   │   ├── values.yaml
│   │   └── install.sh
│   └── mongodb/
│       ├── chart/                # eigenes Helm-Chart: Replica Set mit einem Mitglied, persistent
│       └── install.sh
├── examples/
│   └── demo/demo.yaml            # einfache nginx-Beispielanwendung (Test des Gateways)
├── products/                     # Helm-Charts der Produkte
│   └── shop/
│       └── chart/                # Deployments, Services, HTTPRoute je Dienst (ausgerollt von Argo CD)

├── ansible/                      # Konfiguration der VMs (WSL)
│   ├── prepare.yml               # Playbook: Basis-Konfiguration aller VMs
│   ├── kubernetes.yml            # Playbook: containerd + Kubernetes-Pakete
│   ├── control-plane.yml         # Playbook: kubeadm init, kubeconfig nach WSL
│   ├── workers.yml               # Playbook: kubeadm join, Taint der Control Plane
│   ├── nfs-server.yml            # Playbook: NFS-Server auf nfs-1 (Daten-Disk, Freigabe)
│   ├── requirements.yml          # benötigte Collections
│   ├── roles/
│   │   ├── common/               # Updates, Grundpakete, Swap, Kernel-Module, sysctl
│   │   ├── containerd/           # Container-Runtime (systemd-cgroups)
│   │   ├── kubernetes/           # kubelet, kubeadm, kubectl aus pkgs.k8s.io, gesperrt
│   │   ├── control_plane/        # kubeadm-Konfiguration (Template), init, kubeconfig
│   │   ├── worker/               # Join-Befehl erzeugen, kubeadm join, Label
│   │   └── nfs_server/           # Daten-Disk formatieren/einbinden, NFS-Freigabe
│   └── inventory/
│       ├── hosts.yml             # von Terraform erzeugt, nicht eingecheckt
│       └── group_vars/all.yml    # Verbindung: Benutzer, Schlüssel, SSH-Optionen
└── terraform/                    # Infrastruktur, je Plattform ein Unterordner (später z. B. azure/)
    └── hyper-v/                  # lokal auf Hyper-V
        ├── versions.tf
        ├── providers.tf
        ├── variables.tf
        ├── network.tf                # internal Switch + NAT
        ├── nodes.tf                  # VMs (local.nodes: Rolle, IP, CPU, RAM) + Disk, cloud-init-ISO, VM
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
| `platform/` | WSL (Helm) | Inhalte des Clusters, beginnend mit dem CNI |
| `tools/` | WSL, Bash | Werkzeuge der Arbeitsumgebung installieren |
| `examples/` | WSL (kubectl) | Beispielanwendungen zum Testen (`examples/demo` im Namespace `demo`) |
| `products/` | WSL (Helm) | Helm-Charts der Produkte; der Quellcode der Dienste liegt in eigenen Repos (siehe unten) |
| `terraform/hyper-v/` | Windows, Admin-PowerShell | Netz und VMs auf Hyper-V |

**Trennung von Infrastruktur und Anwendungen**: Dieses Repo beschreibt die Plattform (VMs, Cluster,
gemeinsame Infrastruktur) und enthält die **Helm-Charts** der Produkte. Der **Quellcode** der Dienste
(z. B. catalog-api, orders-api, Frontend) samt Dockerfiles liegt in eigenen Repos; von dort kommen fertige
Images, die die Charts hier nur referenzieren.

Bash-Skripte werden mit `bash <skript>` aufgerufen, nicht über PowerShell. Die `.gitattributes`
(`* text=auto eol=lf`) sorgt dafür, dass sie auch unter Windows mit LF-Zeilenenden ausgecheckt werden.

## Voraussetzungen

- Windows mit aktiviertem **Hyper-V**
- **Terraform** ≥ 1.5 (`winget install Hashicorp.Terraform`)
- **WSL** (Ubuntu 24.04) mit den Werkzeugen aus *Werkzeuge in WSL* (unten)
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

### Werkzeuge in WSL

Alles in der **Ubuntu-WSL** (`wsl -d Ubuntu-24.04`), als normaler Benutzer, nicht als root.

| Werkzeug | Wofür | Installation |
|---|---|---|
| `qemu-utils`, `curl`, `gpg` | Basis-Image konvertieren, Downloads prüfen | apt |
| `openssh-client` | Schlüssel, Zertifikate, SSH | apt (meist vorinstalliert) |
| `whois` | enthält `mkpasswd` für den Konsolen-Passwort-Hash | apt |
| Ansible | Konfiguration der VMs | `pipx` |
| `kubectl` | Cluster bedienen | Binärdatei von `dl.k8s.io`, Version passend zum Cluster |
| Helm | Charts installieren (Cilium usw.) | `tools/install-helm.sh` (apt-Repository des Helm-Projekts) |
| k9s | Terminal-Oberfläche für den Cluster | `tools/install-k9s.sh` |

#### Basis-Pakete

```bash
sudo apt update
sudo apt install -y qemu-utils curl gpg apt-transport-https openssh-client whois pipx
```

#### Ansible

Per `pipx`, damit Ansible aktuell ist und nicht mit den Python-Paketen des Systems kollidiert:

```bash
pipx install --include-deps ansible
pipx ensurepath
exec bash                # Shell neu starten, damit ~/.local/bin im PATH ist
ansible --version
```

Das Paket `ansible` enthält neben `ansible-core` die benötigten Collections (`ansible.posix`, `community.general`).
Aktualisieren: `pipx upgrade --include-injected ansible`.

**Installiert, aber `command not found`?** `pipx` legt die Befehle unter `~/.local/bin` ab. Fehlt das im `PATH`,
meldet `pipx install` trotzdem *already seems to be installed*. Abhilfe: `pipx ensurepath`, dann `exec bash`.
Den Vorschlag `sudo apt install ansible-core` aus der Fehlermeldung **nicht** befolgen: Das legt eine zweite,
ältere Installation ohne die Collections daneben.

#### kubectl

Version passend zum Cluster wählen (`kubeadm version -o short` auf der VM). kubectl darf eine Minor-Version
älter oder neuer sein als der Cluster, gleich ist am einfachsten.

```bash
V=v1.37.2
curl -LO "https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check      # kubectl: OK
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl kubectl.sha256
kubectl version --client
```

Aktualisieren: dieselben Befehle mit neuer Version.

#### Helm

Aus dem offiziellen apt-Repository des Helm-Projekts. Das Skript bindet das Repository (neu) ein und
installiert bzw. aktualisiert Helm; danach kommen Updates auch mit `apt upgrade`.

```bash
bash tools/install-helm.sh
helm version --short
```

#### k9s

Terminal-Oberfläche für Kubernetes. Nutzt dieselbe kubeconfig wie kubectl. Das Skript lädt das Debian-Paket
aus den GitHub-Releases, prüft die SHA-256-Prüfsumme und installiert es; ist die Version schon installiert,
tut es nichts.

```bash
bash tools/install-k9s.sh            # neueste Version
bash tools/install-k9s.sh v0.51.0    # bestimmte Version
k9s
```

| Taste | Wirkung |
|---|---|
| `:pods`, `:svc`, `:nodes`, `:deploy` | Ressourcen-Ansicht wechseln (Tab vervollständigt) |
| `0` | alle Namespaces |
| `/` | Liste filtern |
| `Enter` | hineingehen (z. B. Pod → Container) |
| `l` / `d` / `y` | Logs / describe / YAML |
| `s` | Shell im Container |
| `Ctrl+d` | löschen (mit Rückfrage) |
| `?` | Hilfe |
| `:q` | beenden |

> Das *Kubernetes Dashboard* (Web-UI) ist seit Januar 2026 archiviert. Als Web-Oberfläche empfiehlt die
> Kubernetes SIG UI stattdessen **Headlamp**.

#### Alles prüfen

```bash
qemu-img --version | head -1
ssh -V
ansible --version | head -1
kubectl version --client
helm version --short
k9s version --short
```

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
Copy-Item terraform\hyper-v\terraform.tfvars.example terraform\hyper-v\terraform.tfvars
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

Die VMs selbst stehen in `terraform/hyper-v/nodes.tf` im Block `locals`:

```hcl
nodes = {
  cp-1     = { role = "control_plane", ip = "192.168.250.11", cpus = 2, memory_gb = 4 }
  worker-1 = { role = "worker",        ip = "192.168.250.21", cpus = 2, memory_gb = 2 }
}
```

Konvention: `cp-<n>` (Control Plane) ab `.11`, `worker-<n>` ab `.21`. `role` (`control_plane` oder `worker`)
bestimmt die Gruppe im Ansible-Inventory. IPs außerhalb des Lab-Netzes oder die Gateway-Adresse fallen beim
`terraform plan` auf.

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
- Der Hash landet in der Seed-ISO, in `terraform/hyper-v/.build/` und im State. Nur ein eigenes Lab-Passwort verwenden.
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
cd terraform\hyper-v
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

Ansible installieren: siehe *Werkzeuge in WSL* unter Voraussetzungen.

**Inventory angeben:** In dieser README wird das Inventory explizit mit `-i` übergeben. Wer das nicht
bei jedem Befehl schreiben will, setzt es als Standard (dann kann `-i` entfallen, ein angegebenes `-i` hat Vorrang):

```bash
echo 'export ANSIBLE_INVENTORY=/mnt/c/<pfad-zum-repo>/ansible/inventory/hosts.yml' >> ~/.bashrc
source ~/.bashrc
```

Die gesamte Konfiguration ist YAML, eine `ansible.cfg` (INI-Format) gibt es bewusst nicht:

| Datei | Inhalt |
|---|---|
| `inventory/hosts.yml` | Hosts und Gruppen, erzeugt von Terraform (`terraform/hyper-v/inventory.tf`) aus `local.nodes` in `nodes.tf` |
| `inventory/group_vars/all.yml` | Verbindung für alle VMs: Benutzer `ubuntu`, Schlüssel `~/.ssh/id_ed25519_k8s_lab`, SSH-Optionen |

- `group_vars/` neben dem Inventory lädt Ansible automatisch.
- Das Zertifikat neben dem Schlüssel verwendet OpenSSH automatisch mit.
- Unbekannte Host-Schlüssel werden beim ersten Kontakt übernommen (`StrictHostKeyChecking=accept-new`), geänderte aber abgelehnt.
- Die Gruppen im Inventory ergeben sich aus `role`: `control_plane` und `workers`. Nach jeder Änderung an
  `local.nodes` einmal `terraform apply`, dann ist das Inventory aktuell.

Warum keine `ansible.cfg`: Verzeichnisse unter `/mnt/c` gelten für WSL als *world-writable*, und Ansible
ignoriert eine `ansible.cfg` im aktuellen Ordner dann aus Sicherheitsgründen. Ohne Datei entfällt das Problem.
Was sich nur in einer `ansible.cfg` einstellen lässt, wird bei Bedarf über Umgebungsvariablen gesetzt.

### 10. Verbindung testen (WSL)

Im Repo-Root, Zertifikat gültig (Schritt 4):

```bash
INV=ansible/inventory/hosts.yml
ansible-inventory -i $INV --graph
ansible-inventory -i $INV --host cp-1                        # zeigt auch die Variablen aus group_vars
ansible -i $INV all -m ping                                  # cp-1 | SUCCESS => "ping": "pong"
```

Scheitert der Ping mit `Permission denied`, ist meist das Zertifikat abgelaufen (8 Stunden): `bash ssh/sign-cert.sh -a`.

### 11. Basis-Konfiguration (WSL)

Das Playbook `prepare.yml` wendet die Rolle `common` auf alle VMs an:

| Schritt | Warum |
|---|---|
| `apt update` + `dist-upgrade`, Neustart falls nötig | aktueller Stand vor der Kubernetes-Installation |
| Grundpakete (`curl`, `gpg`, `conntrack`, `socat`, …) | Paketquellen einbinden; `conntrack`/`socat` braucht der kubelet |
| Swap aus (sofort und in `/etc/fstab`) | der kubelet startet standardmäßig nicht mit aktivem Swap |
| Kernel-Module `overlay`, `br_netfilter` (sofort und beim Boot) | Container-Dateisystem und Pod-Netzwerk |
| sysctl `ip_forward`, `bridge-nf-call-ip(6)tables` | wird von den kubeadm-Preflight-Checks geprüft |

Die Werte stehen in `roles/common/defaults/main.yml` und lassen sich dort oder per `group_vars` überschreiben.

```bash
cd /mnt/c/<pfad-zum-repo>
ansible-playbook -i ansible/inventory/hosts.yml ansible/prepare.yml --check --diff   # Trockenlauf
ansible-playbook -i ansible/inventory/hosts.yml ansible/prepare.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/prepare.yml                  # erwartet: changed=0
```

- **Trockenlauf** (`--check --diff`): zeigt, was sich ändern würde, ändert aber nichts. Erkennbar an den
  `--- before / +++ after`-Abschnitten. Danach muss der echte Lauf noch folgen.
- **Zweiter echter Lauf**: muss im `PLAY RECAP` `changed=0` zeigen (Idempotenz). Ein `changed` deutet auf
  einen Task hin, der nicht sauber idempotent geschrieben ist.
- Fakten werden über `ansible_facts['…']` gelesen, nicht über `ansible_…`-Variablen (ab ansible-core 2.24 entfernt). Die Collections `ansible.posix`
und `community.general` sind im Paket `ansible` enthalten; nur bei reinem `ansible-core`:
`ansible-galaxy collection install -r ansible/requirements.yml`.

### 12. Container-Runtime und Kubernetes-Pakete (WSL)

Das Playbook `kubernetes.yml` wendet die Rollen `containerd` und `kubernetes` auf alle VMs an.
Voraussetzung ist Schritt 11.

| Rolle | Was | Warum |
|---|---|---|
| `containerd` | Paket `containerd` aus Ubuntu (`noble-updates`, Version 2.x) | Kubernetes ab 1.36 setzt containerd 2.x voraus |
| | vollständige `config.toml` erzeugen, `SystemdCgroup = true` | kubelet und containerd müssen denselben cgroup-Treiber nutzen |
| | `/etc/crictl.yaml` | `crictl` spricht ohne weitere Angaben mit containerd |
| `kubernetes` | Paketquelle `pkgs.k8s.io` für die Minor-Version (`kubernetes_version`, Standard `1.37`) | offizielles Repository, eines pro Minor-Version |
| | `kubelet`, `kubeadm`, `kubectl` installieren und per `apt-mark hold` sperren | Kubernetes wird kontrolliert per `kubeadm upgrade` aktualisiert, nie durch `apt upgrade` |

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/kubernetes.yml --check --diff
ansible-playbook -i ansible/inventory/hosts.yml ansible/kubernetes.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/kubernetes.yml     # erwartet: changed=0
```

Im Trockenlauf scheitern Tasks, die auf die erst noch einzubindende Paketquelle angewiesen sind. Das ist dort normal.

Prüfen auf der VM:

```bash
containerd --version                                  # 2.x
sudo containerd config dump | grep SystemdCgroup      # SystemdCgroup = true
kubeadm version -o short
apt-mark showhold                                     # kubeadm, kubectl, kubelet
systemctl status kubelet                              # "activating (auto-restart)" ist erwartet
```

Der kubelet startet bis zum `kubeadm init` bzw. `kubeadm join` in einer Schleife neu, weil ihm noch die
Konfiguration fehlt. Das ist kein Fehler.

Andere Kubernetes-Version: `kubernetes_version` in `roles/kubernetes/defaults/main.yml` oder per
`-e kubernetes_version=1.36` setzen. Ein Wechsel auf einem laufenden Cluster ist ein Upgrade und gehört zu `kubeadm upgrade`.

**Warum die Pakete gesperrt sind:** Ein Kubernetes-Update muss in fester Reihenfolge laufen (erst `kubeadm`,
dann `kubeadm upgrade apply` für die Control Plane, danach `kubelet`/`kubectl` Knoten für Knoten), und der
kubelet darf nie neuer sein als der API-Server. Ohne Sperre würde jedes `apt upgrade` – auch das in `prepare.yml` –
die Pakete außer der Reihe aktualisieren.

### 13. Control Plane initialisieren (WSL)

Das Playbook `control-plane.yml` läuft auf dem ersten Host der Gruppe `control_plane`:

1. schreibt `/etc/kubernetes/kubeadm-config.yaml` aus `roles/control_plane/templates/kubeadm-config.yaml.j2`
   und prüft sie mit `kubeadm config validate`,
2. lädt die Images und führt `kubeadm init` aus – **nur beim ersten Lauf** (erkennbar an `/etc/kubernetes/admin.conf`),
3. richtet die kubeconfig für `ubuntu` auf der VM ein und holt sie nach WSL: `~/.kube/k8s-lab.conf`.

| Einstellung | Wert | Variable (`roles/control_plane/defaults/main.yml`) |
|---|---|---|
| Kubernetes-Version | wie das installierte `kubeadm` | – |
| API-Server | `<ip-von-cp-1>:6443` | – |
| Pod-Netz | `10.244.0.0/16` | `control_plane_pod_subnet` |
| Service-Netz | `10.96.0.0/12` | `control_plane_service_subnet` |
| kube-proxy | wird installiert (Standard) | – |

Pod- und Service-Netz dürfen sich nicht mit dem Lab-Netz oder Firmennetzen überschneiden. Prüfen auf dem Host:
`Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -like "10.*"`. Netze hinter dem
Standard-Gateway oder nur per VPN sichtbare Netze erscheinen dort nicht.

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/control-plane.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/control-plane.yml   # erwartet: changed=0
```

**kubectl in WSL** (Installation siehe *Werkzeuge in WSL*), dann die kubeconfig als Standard setzen:

```bash
echo 'export KUBECONFIG=$HOME/.kube/k8s-lab.conf' >> ~/.bashrc
source ~/.bashrc
```

Helm nutzt dieselbe kubeconfig. Test: `helm list -A` (leer, aber ohne Fehler).

Prüfen:

```bash
kubectl get nodes -o wide          # cp-1  NotReady  control-plane
kubectl get pods -A                # coredns: Pending, übrige Pods: Running
```

`NotReady` und `Pending` bei CoreDNS sind erwartet: Es gibt noch kein Pod-Netzwerk (CNI). Das kommt mit Cilium.

> `admin.conf` ist die Administrator-kubeconfig mit vollen Rechten auf den Cluster. Sie liegt nur in WSL
> (`~/.kube`) und auf der VM, niemals im Repo.

Den Cluster zurücksetzen (z. B. für einen neuen Versuch): auf der VM `sudo kubeadm reset -f`, danach das
Playbook erneut ausführen. Einfacher ist im Lab ein Neuaufbau der VM per Terraform.

### 14. Pod-Netzwerk mit Cilium (WSL)

Cilium ist das CNI: Es vergibt Pod-IPs und verbindet Pods über alle Knoten. Erst danach wird der Knoten
`Ready` und CoreDNS startet. In dieser Ausbaustufe macht Cilium **nur** das Pod-Netzwerk, kube-proxy bleibt.

| Einstellung (`platform/cilium/values.yaml`) | Wert | Warum |
|---|---|---|
| `kubeProxyReplacement` | `"false"` | kube-proxy bleibt für Services zuständig |
| `ipam.mode` | `kubernetes` | Pod-IPs aus dem podCIDR des Knotens (aus `podSubnet` 10.244.0.0/16) statt Ciliums eigenem Bereich `10.0.0.0/8` |
| `operator.replicas` | `1` | Standard 2 auf verschiedenen Knoten; im Ein-Knoten-Cluster bliebe einer `Pending` |
| `hubble.enabled` | `true` | Flow-Daten werden erfasst (Relay und UI: Schritt 15) |

**Version:** Cilium 1.20 läuft u. a. bei AKS und DigitalOcean mit Kubernetes 1.37. Die eingesetzte
Chart-Version steht in `platform/cilium/install.sh` (`CILIUM_VERSION`), zusammen mit der `values.yaml` im Repo.
Neuere Patch-Stände der 1.20-Reihe anzeigen:

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update cilium
helm search repo cilium/cilium --versions | head -5
```

Installieren bzw. aktualisieren:

```bash
bash platform/cilium/install.sh
kubectl -n kube-system get pods -o wide              # coredns: Running mit 10.244.x-IP
```

Das Skript zeigt zuerst, gegen welchen Cluster es läuft, prüft, dass jeder Knoten einen podCIDR hat
(sonst findet `ipam.mode: kubernetes` keine Adressen), installiert per `helm upgrade --install` und wartet,
bis Agent und Operator bereit sind. Eine andere Version einmalig: `CILIUM_VERSION=1.20.5 bash platform/cilium/install.sh`;
dauerhaft: die Zeile im Skript ändern und committen.

`helm upgrade --install` ist idempotent: legt Cilium beim ersten Mal an und übernimmt später Änderungen an der
`values.yaml`. Die eingesetzte Version zeigt `helm list -n kube-system`.

**Pods auf der Control Plane erlauben** – solange es keine Worker gibt:

```bash
kubectl taint nodes cp-1 node-role.kubernetes.io/control-plane:NoSchedule-
```

Kubernetes hält normale Pods per *Taint* von Control-Plane-Knoten fern. Ohne Worker bliebe jede eigene
Anwendung `Pending`. Sobald Worker dazukommen, kann der Taint wieder gesetzt werden:
`kubectl taint nodes cp-1 node-role.kubernetes.io/control-plane:NoSchedule`.

**Funktionstest** (Pod-Netzwerk, Service über kube-proxy, DNS über CoreDNS):

```bash
kubectl run web --image=nginx --port=80
kubectl expose pod web --port=80
kubectl wait --for=condition=Ready pod/web --timeout=120s
kubectl run test --image=busybox --rm -i --restart=Never -- wget -qO- http://web | head -4
kubectl delete pod web && kubectl delete service web
```

Erwartet ist der Anfang der nginx-Startseite (`<!DOCTYPE html>`…). kubectl mischt beim Anhängen an den Pod
Hinweise in die Ausgabe ("All commands and output … recorded", "If you don't see a command prompt …"). Ist der
Pod schneller fertig, als kubectl sich anhängen kann, erscheint zusätzlich *couldn't attach … falling back to
streaming logs*. Beides ist für den Test ohne Bedeutung.

### 15. Hubble: Netzwerkverkehr sichtbar machen (WSL)

Hubble ist das Beobachtungswerkzeug von Cilium. Es erfasst per eBPF jede Verbindung im Cluster – Quelle, Ziel,
Port, Protokoll und ob sie **durchgelassen oder verworfen** wurde.

| Teil | Aufgabe | `values.yaml` |
|---|---|---|
| Hubble im Cilium-Agent | erfasst die Flows auf jedem Knoten | `hubble.enabled: true` |
| Hubble Relay | sammelt die Flows aller Knoten | `hubble.relay.enabled: true` |
| Hubble UI | Weboberfläche: Service Map und Flow-Tabelle | `hubble.ui.enabled: true` |

Aktivieren (die Werte stehen bereits in `platform/cilium/values.yaml`):

```bash
bash platform/cilium/install.sh
kubectl -n kube-system rollout status deploy/hubble-relay
kubectl -n kube-system rollout status deploy/hubble-ui
```

Aufrufen per Port-Forwarding (läuft, bis es mit `Ctrl+C` beendet wird):

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

Danach im Browser unter Windows `http://localhost:12000` öffnen (im Mirrored-Modus teilen sich WSL und Windows
`localhost`). Namespace oben links wählen, z. B. `kube-system` oder `default`.

Verkehr zum Anschauen erzeugen, in einem zweiten Terminal:

```bash
kubectl run web --image=nginx --port=80 && kubectl expose pod web --port=80
kubectl wait --for=condition=Ready pod/web --timeout=120s
kubectl run client --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -qO- http://web >/dev/null; sleep 2; done'
# ... in der UI zuschauen, danach aufräumen:
kubectl delete pod client web --now && kubectl delete service web
```

Im Namespace `default` zeigt die Service Map dann `client` → `web`, dazu die DNS-Anfragen an CoreDNS in `kube-system`.
Die Flow-Tabelle zeigt jede Verbindung mit dem Ergebnis *forwarded* oder *dropped*. Verworfene Pakete samt
Grund (z. B. eine Network Policy) sind später der wichtigste Einstieg in die Fehlersuche.

### 16. Worker-Knoten (PowerShell + WSL)

**1. VMs anlegen** – in `terraform/hyper-v/nodes.tf` die Worker in `local.nodes` eintragen bzw. einkommentieren:

```hcl
nodes = {
  cp-1     = { role = "control_plane", ip = "192.168.250.11", cpus = 2, memory_gb = 4 },
  worker-1 = { role = "worker",        ip = "192.168.250.12", cpus = 2, memory_gb = 2 },
  worker-2 = { role = "worker",        ip = "192.168.250.13", cpus = 2, memory_gb = 2 },
}
```

```powershell
terraform plan     # erwartet: 7 to add, 1 to destroy (je Worker Disk, ISO, VM; das Inventory wird neu geschrieben)
terraform apply
```

Das eine *destroy* betrifft nur `local_file.ansible_inventory`: Bei `local_file` erzwingt jede Inhaltsänderung
ein Ersetzen der Datei. Steht dort eine bestehende VM, abbrechen.
Admin-Rechte sind dafür nicht nötig, solange das NAT unverändert bleibt. Speicherbedarf jetzt insgesamt 8 GB RAM.

**2. Konfigurieren** (WSL, Repo-Root, gültiges Zertifikat). Die ersten beiden Playbooks laufen auf allen
Knoten; auf `cp-1` ändern sie nichts mehr:

```bash
INV=ansible/inventory/hosts.yml
ansible -i $INV all -m ping                 # neue Host-Schlüssel werden automatisch übernommen
ansible-playbook -i $INV ansible/prepare.yml
ansible-playbook -i $INV ansible/kubernetes.yml
ansible-playbook -i $INV ansible/workers.yml
```

`workers.yml`

1. erzeugt auf der Control Plane einen Join-Befehl mit einem Token, das 15 Minuten gilt,
2. führt `kubeadm join` auf jedem Worker aus, der noch nicht zum Cluster gehört (erkennbar an `/etc/kubernetes/kubelet.conf`),
3. wartet, bis der Knoten `Ready` ist, und setzt das Label `node-role.kubernetes.io/worker`,
4. setzt den Taint der Control Plane wieder: Anwendungen laufen ab jetzt nur noch auf den Workern.

**3. Prüfen**

```bash
kubectl get nodes -o wide          # cp-1 control-plane, worker-1/2 worker, alle Ready
kubectl -n kube-system get pods -o wide -l k8s-app=cilium   # ein Cilium-Agent pro Knoten
```

Pod-Verkehr über Knotengrenzen (läuft über einen Tunnel zwischen den VMs) – zwei Pods auf verschiedenen Workern:

```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80
kubectl rollout status deploy/web
kubectl get pods -o wide -l app=web             # auf worker-1 und worker-2 verteilt
kubectl run client --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -qO- http://web >/dev/null; sleep 2; done'
# Hubble UI: client -> web, Flows zu beiden Pods
kubectl delete pod client --now && kubectl delete deployment,service web
```

Optional, jetzt da es mehrere Knoten gibt: `operator.replicas` in `platform/cilium/values.yaml` auf `2` setzen
(Ausfallsicherheit des Cilium-Operators) und `bash platform/cilium/install.sh`.

### 17. LoadBalancer-IPs und Gateway (PowerShell + WSL)

Anwendungen werden über **ein zentrales Gateway** von außen erreichbar: eine LoadBalancer-IP, dahinter
Routing nach Hostnamen (Gateway API). Die Anwendungen selbst behalten normale ClusterIP-Services.

```
Browser ── demo.k8s-lab ──▶ 192.168.250.200 ──(statische Route)──▶ cp-1 ──(kube-proxy)──▶ Envoy (Gateway "lab")
                                                                               └─ HTTPRoute ─▶ Service demo ─▶ Pods
```

| Aufgabe | Wer | Datei |
|---|---|---|
| LoadBalancer-IP vergeben | Cilium LB-IPAM | `platform/cilium/lb-ippool.yaml` |
| IP im Lab-Netz erreichbar machen | statische Route auf dem Windows-Host | – |
| Verkehr an die IP weiterleiten | kube-proxy | – |
| Gateway (Routing nach Hostname) | Envoy Gateway | `platform/envoy-gateway/`, `platform/gateway/gateway.yaml` |
| Route einer Anwendung | `HTTPRoute` | z. B. `examples/demo/demo.yaml` |

**Warum Envoy Gateway und nicht Ciliums Gateway:** Cilium 1.20 setzt für seine Gateway-API-Implementierung den
kube-proxy-Ersatz voraus (`kubeProxyReplacement=true`), wir behalten kube-proxy aber vorerst. Für die
L2-Bekanntgabe von LoadBalancer-IPs gilt dasselbe, deshalb die statische Route. Der Umstieg auf Cilium
für beides ist als Option vorgemerkt (siehe Ausblick).

**Warum die Route reicht:** Das Lab-Netz ist ein interner Switch hinter NAT und ohnehin nur vom Windows-Host
aus erreichbar. Die Route leistet für diesen einen Client dasselbe wie MetalLB oder L2 Announcements, nur
ohne automatisches Umschalten, wenn `cp-1` ausfällt.

**1. IP-Pool** (WSL) – `install.sh` legt ihn nach Cilium an:

```bash
bash platform/cilium/install.sh
kubectl get ciliumloadbalancerippools          # lab-pool, IPS AVAILABLE 8
```

Die Adressen `192.168.250.200`–`207` dürfen keiner VM in `terraform/hyper-v/nodes.tf` zugewiesen werden.

**2. Route** (Admin-PowerShell, einmalig, `-p` = bleibt nach Neustarts erhalten):

```powershell
route -p add 192.168.250.200 mask 255.255.255.248 192.168.250.11
route print -4 192.168.250.*
```

Pakete an den ganzen Pool gehen damit an `cp-1`; kube-proxy dort leitet sie an den passenden Pod weiter,
egal auf welchem Knoten er läuft. Entfernen: `route delete 192.168.250.200`.

**3. Envoy Gateway** (WSL) – installiert Controller und Gateway-API-CRDs:

```bash
bash platform/envoy-gateway/install.sh
```

Version: `EG_VERSION` im Skript. Envoy Gateway v1.10 ist laut Kompatibilitätsmatrix mit Kubernetes 1.34–1.37
und Gateway API v1.6.1 getestet. Helm installiert die CRDs aus der Chart nur bei der Erstinstallation;
bei einem Versionswechsel die Upgrade-Hinweise in den Release Notes beachten.

**4. Gateway anlegen** (WSL):

```bash
kubectl apply -f platform/gateway/gateway.yaml
kubectl -n gateway get gateway lab              # ADDRESS 192.168.250.200, PROGRAMMED True
kubectl -n envoy-gateway-system get svc         # envoy-gateway-lab-…  LoadBalancer  192.168.250.200
```

Die feste Adresse kommt über die Annotation `lbipam.cilium.io/ips` am Service, gesetzt über die
`EnvoyProxy`-Ressource, auf die das Gateway verweist. Dort steht außerdem `externalTrafficPolicy: Cluster`:
Envoy Gateway setzt standardmäßig `Local`, dann nimmt nur ein Knoten mit Envoy-Pod Verkehr für die IP an.
Unsere Route führt aber immer zu `cp-1`, während der Envoy-Pod auf einem Worker läuft – mit `Local` endet
jede Anfrage im Timeout.

**5. Testen** mit der Beispielanwendung:

```bash
kubectl apply -f examples/demo/demo.yaml
kubectl -n demo get httproute demo             # HOSTNAMES demo.k8s-lab
curl --resolve demo.k8s-lab:80:192.168.250.200 http://demo.k8s-lab/ | head -4
```

`--resolve` ersetzt für den Test den Eintrag in der Hosts-Datei. Hängt `curl` aus WSL, übernimmt WSL die
Windows-Route offenbar nicht; dann zusätzlich in WSL (gilt bis zum nächsten `wsl --shutdown`):
`sudo ip route add 192.168.250.200/29 via 192.168.250.11`.

**Im Browser unter Windows:** Hosts-Datei als Administrator bearbeiten
(`C:\Windows\System32\drivers\etc\hosts`) und eintragen:

```
192.168.250.200  demo.k8s-lab
```

Per PowerShell (als Administrator) – mit führendem Zeilenumbruch, falls die Datei ohne Umbruch endet;
sonst hängt der Eintrag an der letzten Zeile und beschädigt sie:

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "`r`n192.168.250.200  demo.k8s-lab"
ipconfig /flushdns
Resolve-DnsName demo.k8s-lab        # 192.168.250.200
```

Danach `http://demo.k8s-lab` öffnen (mit `http://`, sonst behandeln manche Browser die Eingabe als Suche).
Weitere Anwendungen bekommen eine eigene `HTTPRoute` mit eigenem Hostnamen und eine weitere Zeile in der
Hosts-Datei – aber keine neue IP und keine neue Route. WSL übernimmt die Hosts-Datei erst nach `wsl --shutdown`.

Aufräumen: `kubectl delete -f examples/demo/demo.yaml`.

### Namespaces: Produkte und gemeinsame Infrastruktur

| Namespace | Inhalt | Wem gehört er |
|---|---|---|
| `shop` | Dienste des Produkts (catalog-api, orders-api, Frontend) | dem Produkt |
| `rabbitmq` | RabbitMQ, ein vhost pro Produkt (`shop`), ein Benutzer pro Dienst | der Plattform, von mehreren Produkten nutzbar |
| `mongodb` | MongoDB, eine Datenbank und ein Benutzer pro Dienst | der Plattform, von mehreren Produkten nutzbar |
| `gateway`, `envoy-gateway-system`, `kube-system` | Gateway, Controller, Cilium, NFS-CSI | der Plattform |

**Modell "geteilte Plattform"**: Ein MongoDB und ein RabbitMQ dienen allen Produkten; getrennt wird logisch –
MongoDB über eigene Datenbanken und Benutzer, RabbitMQ über eigene vhosts und Benutzer. Jeder Dienst besitzt
seine Daten (`catalog-api` darf nur `catalog` lesen/schreiben), ohne eigene Server-Instanz. Die Alternative –
eigene Instanzen je Produkt – bringt mehr Unabhängigkeit (Versionen, Wartung, Last) für mehr Betriebsaufwand.

**Zugangsdaten über Namespace-Grenzen**: Pods lesen Secrets nur im eigenen Namespace. Deshalb legt jedes
Infrastruktur-Chart die Zugangsdaten eines Dienstes **im Namespace des Dienstes** an – gesteuert über die Liste
`clients` in seiner `values.yaml`. Der Administrator entscheidet dort, wer Zugang bekommt; der Dienst findet sein
Secret im eigenen Namespace vor:

| Infrastruktur | Eintrag in `values.yaml` | Secret im Namespace des Dienstes |
|---|---|---|
| RabbitMQ | `{ name: catalog-api, namespace: shop, vhost: shop }` | `rabbitmq-catalog-api`: `host`, `port`, `vhost`, `username`, `password` |
| MongoDB | `{ name: catalog-api, namespace: shop, database: catalog }` | `mongodb-catalog-api`: `username`, `password`, `database`, `connection-string` |

Die Passwörter entstehen zufällig beim ersten Install, liegen im Verwaltungs-Secret im Namespace der
Infrastruktur und werden bei jedem Update von dort übernommen. Ein zweites Produkt ist ein weiterer Eintrag in
`clients` (und bei RabbitMQ in `vhosts`). Die Produkt-Namespaces legt das jeweilige `install.sh` an, falls sie
fehlen – nicht das Chart, damit ein `helm uninstall` sie nicht mitlöscht.

**Umzug vom bisherigen Namespace `demo`** (falls RabbitMQ/MongoDB dort installiert waren):

```bash
helm -n demo uninstall rabbitmq mongodb 2>/dev/null; kubectl delete namespace demo
bash platform/rabbitmq/install.sh
bash platform/mongodb/install.sh
```

### 18. RabbitMQ (WSL)

Message-Broker für die Dienste: Sie rufen sich nicht direkt auf, sondern tauschen sich nur über RabbitMQ aus.
Bereitgestellt über ein **eigenes Helm-Chart** (`platform/rabbitmq/chart`) mit dem Docker Official Image
`rabbitmq:4.4-management`, im Namespace `rabbitmq`:

| Datei | Inhalt |
|---|---|
| `values.yaml` | Image, Administrator, `vhosts`, `clients` (Dienste), Management-UI, Ressourcen |
| `templates/secret.yaml` | Verwaltungs-Secret: Administrator und Passwörter der Dienste |
| `templates/client-secrets.yaml` | je Dienst ein Secret `rabbitmq-<dienst>` im Namespace des Dienstes |
| `templates/configmap-setup.yaml` | Einrichtungsskript `setup.sh`: vhosts, Benutzer der Dienste, Rechte |
| `templates/deployment.yaml` | ein Broker, `Recreate`, Probes; Startbefehl führt `setup.sh` im Hintergrund aus |
| `templates/service.yaml` | AMQP (5672) und Management-UI (15672), nur im Cluster |
| `templates/httproute.yaml` | Management-UI über das Gateway (`rabbitmq.k8s-lab`), nur wenn die Gateway-API-CRDs vorhanden sind |

| Bewusste Vereinfachung | Folge |
|---|---|
| ein einzelner Broker als Deployment, kein Operator | kein Clustering, Upgrades per neuem Image-Tag |
| keine Persistenz | Nachrichten und Queues gehen bei einem Neustart verloren; vhosts und Benutzer legt `setup.sh` bei jedem Start neu an |

**Benutzer**: `admin` (Verwaltung, Management-UI) aus dem Image (`RABBITMQ_DEFAULT_USER`). Die Dienste bekommen je einen
eigenen Benutzer mit vollen Rechten auf **ihrem** vhost (`clients` in `values.yaml`), angelegt per `rabbitmqctl`.
Fehlt ein Recht, lehnt RabbitMQ die Verbindung des Dienstes zu einem fremden vhost ab.

**Einrichtung beim Start**: Der Container startet mit
`gosu rabbitmq bash /opt/lab/setup.sh & exec docker-entrypoint.sh rabbitmq-server` – das Skript im Hintergrund,
danach der Broker wie im Image vorgesehen. Das Skript wartet auf den Broker und schreibt ins Container-Log
(`kubectl -n rabbitmq logs deploy/rabbitmq | grep lab-setup`). Manuell wiederholen:
`kubectl -n rabbitmq exec deploy/rabbitmq -- bash /opt/lab/setup.sh`.

| Erfahrung beim Aufbau | Folge für die Lösung |
|---|---|
| `postStart`-Hook scheiterte (Container in `CrashLoopBackOff`, Events nur „PostStartHook failed“) | kein Hook, sondern Startbefehl mit Hintergrundskript |
| Als root aufgerufen, legt `rabbitmqctl` das fehlende Erlang-Cookie als root an; der Broker (Benutzer `rabbitmq`) kann es nicht lesen: `.erlang.cookie: eacces` | Skript läuft per `gosu` als `rabbitmq` und wartet, bis der Broker das Cookie angelegt hat |
| `rabbitmqctl await_startup` scheitert sofort, solange der Erlang-Knoten noch nicht erreichbar ist | Warteschleife um `await_startup` |

**Unabhängig vom Gateway:** Dienste verbinden sich über `rabbitmq.rabbitmq.svc.cluster.local:5672`. Das Gateway ist
nur Komfort für die Management-UI: Ist Envoy Gateway installiert (Schritt 17), legt das Chart die Route
`rabbitmq.k8s-lab` an; fehlen die Gateway-API-CRDs, überspringt es sie. Envoy Gateway nachträglich installiert?
`install.sh` erneut ausführen.

**Installieren:**

```bash
bash platform/rabbitmq/install.sh
kubectl -n rabbitmq get pods,svc,httproute
kubectl -n shop get secret rabbitmq-catalog-api rabbitmq-orders-api
kubectl -n rabbitmq exec deploy/rabbitmq -- rabbitmqctl list_permissions -p shop
```

**Management-UI** über das Gateway: Hosts-Datei ergänzen (`192.168.250.200  rabbitmq.k8s-lab`), `http://rabbitmq.k8s-lab`
öffnen, mit dem Administrator anmelden. Ohne Gateway: `kubectl -n rabbitmq port-forward svc/rabbitmq 15672:15672`,
dann `http://localhost:15672`. Route abschalten: `--set management.httpRoute.enabled=false`.

**Dienst anbinden** (Ausschnitt eines Deployments im Namespace `shop`):

```yaml
env:
  - name: RabbitMQ__Host
    valueFrom: { secretKeyRef: { name: rabbitmq-catalog-api, key: host } }
  - name: RabbitMQ__VirtualHost
    valueFrom: { secretKeyRef: { name: rabbitmq-catalog-api, key: vhost } }
  - name: RabbitMQ__Username
    valueFrom: { secretKeyRef: { name: rabbitmq-catalog-api, key: username } }
  - name: RabbitMQ__Password
    valueFrom: { secretKeyRef: { name: rabbitmq-catalog-api, key: password } }
```

Zugangsdaten anzeigen: `helm -n rabbitmq get notes rabbitmq`. Chart ohne Cluster prüfen:
`helm lint platform/rabbitmq/chart`, `helm template rabbitmq platform/rabbitmq/chart -n rabbitmq`.

### 19. Speicher (NFS) und MongoDB (PowerShell + WSL)

MongoDB läuft im Cluster wie im Produktivaufbau und braucht persistenten Speicher. Er wird **dynamisch**
bereitgestellt: Ein PVC mit der StorageClass `standard` erzeugt automatisch ein Verzeichnis auf dem
NFS-Server. Pods sind dadurch an keinen Knoten gebunden. Hintergrund und Abwägung: *Speicher: Optionen und Entscheidung*.

```
Pod (beliebiger Knoten) ─ PVC data-mongodb-0 (StorageClass standard)
                              │  NFS-CSI-Treiber legt an: /srv/nfs/k8s/pvc-…
                              ▼
        nfs-1 (192.168.250.20): Daten-Disk (XFS) unter /srv/nfs, Freigabe /srv/nfs/k8s
```

**1. NFS-Server-VM** – in `terraform/hyper-v/nodes.tf`:

```hcl
nfs-1 = { role = "nfs", ip = "192.168.250.20", cpus = 1, memory_gb = 1 },
...
data_disks = {
  nfs-1 = 50     # GB, eigene Daten-Disk (data.vhdx), in der VM /dev/sdb
}
```

```powershell
terraform plan      # neu: nfs-1 mit OS-Disk, Daten-Disk, ISO, VM; Inventory mit Gruppen k8s und nfs
terraform apply
```

Die Daten-Disk ist eine eigene Ressource (`hyperv_vhd.data`): Wird nur die VM neu gebaut (Neuaufbau Variante A),
bleiben die Daten erhalten. Das Inventory hat jetzt die Gruppen `k8s` (= `control_plane` + `workers`) und `nfs`;
`prepare.yml` und `kubernetes.yml` laufen nur auf `k8s`.

**2. NFS-Server und -Client** (WSL):

```bash
INV=ansible/inventory/hosts.yml
ansible -i $INV all -m ping
ansible-playbook -i $INV ansible/nfs-server.yml      # nfs-1
ansible-playbook -i $INV ansible/prepare.yml         # installiert nfs-common auf den Kubernetes-Knoten
```

`nfs-server.yml` (Rolle `nfs_server`):

| Schritt | Detail |
|---|---|
| Daten-Disk formatieren | XFS (von MongoDB empfohlen), **nur wenn noch kein Dateisystem vorhanden ist**; bricht ab, wenn das Gerät Partitionen hat (Schutz vor der falschen Disk) |
| einbinden | `/srv/nfs`, per UUID, `noatime` |
| freigeben | `/srv/nfs/k8s` für `192.168.250.0/24` mit `rw,sync,no_subtree_check,no_root_squash` |

`no_root_squash` ist nötig, weil der CSI-Treiber die Verzeichnisse als root anlegt und kubelet ihre Gruppe
(`fsGroup`) setzt. Im Lab vertretbar, da die Freigabe nur im Lab-Netz sichtbar ist.

**3. NFS-CSI-Treiber und StorageClass** (WSL):

```bash
bash platform/nfs-csi/install.sh
kubectl get storageclass                    # standard   nfs.csi.k8s.io   Delete   Immediate   true
```

| Einstellung (`platform/nfs-csi/values.yaml`) | Wert | Warum |
|---|---|---|
| Name der StorageClass | `standard` | neutral: Charts fordern `standard` an, in Azure zeigt eine StorageClass gleichen Namens auf Azure Disks |
| `server`, `share` | `192.168.250.20`, `/srv/nfs/k8s` | nfs-1 |
| `onDelete` | `retain` | Verzeichnis bleibt beim Löschen eines PVC erhalten; Aufräumen ist eine bewusste Handlung |
| `mountOptions` | `nfsvers=4.1`, `hard`, `noatime` | `hard`/`noatime` laut MongoDB-Empfehlung für NFS |
| keine Standard-StorageClass | – | jedes PVC nennt `standard` ausdrücklich |

Ein Volume ist bei NFS nicht auf seine Größe begrenzt; die Gesamtgrenze ist die Daten-Disk von nfs-1 (50 GB).
Grenzen pro Namespace: `ResourceQuota`/`LimitRange` (siehe *Speicher: Optionen und Entscheidung*).

**Test:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc nfs-test                    # Bound
kubectl delete pvc nfs-test                 # Verzeichnis bleibt auf nfs-1 (onDelete: retain)
```

**4. MongoDB** – eigenes Helm-Chart (`platform/mongodb/chart`) mit dem Docker Official Image `mongo:8.3`,
Volume aus der StorageClass `standard` (`persistence.storageClass`):

| Datei | Inhalt |
|---|---|
| `templates/statefulset.yaml` | ein Mitglied, Volume per `volumeClaimTemplates`, Keyfile, WiredTiger-Cache passend zum Limit |
| `templates/services.yaml` | Headless Service (fester DNS-Name des Mitglieds) und normaler Service |
| `templates/secret.yaml` | Verwaltungs-Secret im Namespace `mongodb`: Root, Keyfile, Passwörter der Dienste |
| `templates/client-secrets.yaml` | je Dienst ein Secret `mongodb-<dienst>` im Namespace des Dienstes, mit fertigem `connection-string` |
| `templates/init-job.yaml` | Helm-Hook nach jedem Install/Upgrade: `rs.initiate` (falls nötig), Benutzer der Dienste anlegen/aktualisieren |

| Entscheidung | Warum |
|---|---|
| **Replica Set mit einem Mitglied** (`rs0`) | verhält sich für Anwendungen wie ein produktives Replica Set (Transaktionen, Change Streams); später auf drei Mitglieder erweiterbar |
| **Keyfile** | Pflicht für ein Replica Set mit Authentifizierung, auch bei nur einem Mitglied |
| **Root-Benutzer nur zur Verwaltung**, je Dienst ein Benutzer mit `readWrite` auf seiner Datenbank (`clients`) | geringste nötige Rechte; jeder Dienst besitzt seine Daten |
| Passwörter und Keyfile zufällig erzeugt, bei Updates aus dem Secret übernommen | nichts davon im Repo |

```bash
bash platform/mongodb/install.sh
kubectl -n mongodb get statefulset,pod,pvc -l app.kubernetes.io/instance=mongodb
kubectl -n shop get secret mongodb-catalog-api mongodb-orders-api
```

`install.sh` prüft vorher, ob die StorageClass `standard` existiert, und wartet (`--wait`), bis MongoDB bereit
ist, bevor der Init-Job läuft. Ergebnis des Jobs: `kubectl -n mongodb logs job/mongodb-init` (er wird nach
Erfolg gelöscht; bei Fehlern bleibt er stehen).

**Prüfen** (in der VM bzw. im Pod):

```bash
kubectl -n mongodb exec mongodb-0 -- bash -c \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --quiet --eval "rs.status().members.map(m => m.name + \" \" + m.stateStr)"'
# [ 'mongodb-0.mongodb-headless.mongodb.svc.cluster.local:27017 PRIMARY' ]
```

**Anwendungen** bekommen den Connection-String aus dem Secret in ihrem Namespace:

```yaml
env:
  - name: ConnectionStrings__MongoDb
    valueFrom:
      secretKeyRef:
        name: mongodb-catalog-api
        key: connection-string
```

**Lokal** (WSL, z. B. für `dotnet run` oder MongoDB Compass) per Port-Forwarding – mit `directConnection=true`,
weil der Name des Mitglieds nur im Cluster auflösbar ist:

```bash
kubectl -n mongodb port-forward svc/mongodb 27017:27017
# mongodb://catalog-api:<passwort>@localhost:27017/catalog?directConnection=true&authSource=admin
kubectl -n shop get secret mongodb-catalog-api -o jsonpath='{.data.password}' | base64 -d; echo
```

**Daten bleiben erhalten** – auch über `helm uninstall` hinweg (Helm löscht die PVCs eines StatefulSets nicht)
und nach Löschen des PVC (Verzeichnis bleibt auf nfs-1, `onDelete: retain`). Ein neues PVC bekommt allerdings ein
**neues** Verzeichnis; alte Daten bindet man nur gezielt wieder ein. Bleibt der Pod `Pending`, zeigt
`kubectl -n mongodb describe pvc data-mongodb-0` die Ursache (z. B. NFS-Server nicht erreichbar).

### 20. Argo CD (WSL)

Ab hier verwaltet **Argo CD** die Produkte: Es beobachtet dieses Repo und hält den Cluster auf dem Stand im Git
(GitOps). Helm-Charts bleiben das Format; Argo CD ersetzt nur den manuellen `helm upgrade`. Argo CD selbst
installiert ein Skript, weil es vor allem anderen da sein muss.

| Datei | Inhalt |
|---|---|
| `platform/argocd/values.yaml` | Abweichungen von der Chart `argo/argo-cd`: `server.insecure` (TLS endet am Gateway), HTTPRoute `argocd.k8s-lab`, kein Dex (SSO) |
| `platform/argocd/install.sh` | Chart-Version (10.18.2 = Argo CD v3.6.2) + Installation in den Namespace `argocd` |
| `platform/argocd/apps/*.yaml` | Argo-CD-Applications, z. B. `shop.yaml` |

```bash
bash platform/argocd/install.sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Hosts-Datei ergänzen (`192.168.250.200  argocd.k8s-lab`), `http://argocd.k8s-lab` öffnen, Anmeldung `admin` mit
dem Passwort oben. Die Chart bringt eigene NetworkPolicies mit; Cilium setzt sie durch – der Server ist für
Verkehr vom Gateway offen.

**Was Argo CD verwaltet** (derzeit): nur das Produkt `shop`. Plattform-Komponenten (Cilium, Gateway, RabbitMQ,
MongoDB, NFS-CSI) bleiben bei ihren Skripten; eine Übernahme ist ein späterer Schritt (siehe *Ausblick*).

### 21. Produkt `shop` (WSL)

Die Dienste des Produkts kommen als fertige Images aus ihren eigenen Repos (Build per GitHub Actions,
Version per GitVersion, Registry ghcr.io). Hier liegt nur das **Helm-Chart des Produkts**
(`products/shop/chart`), ausgerollt von Argo CD:

| Datei | Inhalt |
|---|---|
| `values.yaml` | Hostname (`shop.k8s-lab`), Gateway, vertrauenswürdiges Pod-Netz, `services`: je Dienst Image, Tag, Port, Pfad, Probes, Ressourcen |
| `templates/deployments.yaml`, `templates/services.yaml` | je Dienst ein Deployment und ein ClusterIP-Service |
| `templates/httproute.yaml` | eine Route für das Produkt, je Dienst eine Regel nach Pfad; der Präfix wird entfernt (`/api/catalog/x` → `/x`) und per `X-Forwarded-Prefix` gemeldet |
| `platform/argocd/apps/shop.yaml` | Application: Quelle `products/shop/chart` im Branch `develop`, Ziel Namespace `shop`, automatischer Abgleich |

Derzeitiger Dienst: `catalogservice` (Repo `sschabbach-mse/CatalogService`), erreichbar unter
`http://shop.k8s-lab/api/catalog/`:

| Von außen | Im Dienst |
|---|---|
| `/api/catalog/v1/products`, `/api/catalog/v1/products/{id}` | `/v1/products…` (Asp.Versioning) |
| `/api/catalog/openapi/v1.json` | `/openapi/v1.json` |
| – (nur im Cluster) | `/health/live` (Liveness-Probe), `/health/ready` (Readiness-Probe) |

**Zusammenspiel Gateway ↔ Dienst:** Das Gateway entfernt `/api/catalog` und setzt `X-Forwarded-Prefix: /api/catalog`.
Der Dienst wertet `X-Forwarded-*` nur von Proxys aus dem Pod-Netz aus (`trustedProxyNetworks` →
Umgebungsvariable `ForwardedHeaders__KnownNetworks__0=10.244.0.0/16`); so enthält z. B. der `Location`-Header nach
`POST` den vollständigen äußeren Pfad. Ohne den Eintrag ignoriert ASP.NET die Header stillschweigend.

**Probes:** `probes.liveness`/`probes.readiness` je Dienst (HTTP-Pfade). Ohne `probes` prüft Kubernetes nur, ob der
Port offen ist.

**Voraussetzungen**

- Das Chart ist nach `develop` **gepusht** – Argo CD liest aus GitHub, nicht aus dem lokalen Arbeitsverzeichnis.
- Das Paket auf ghcr.io ist öffentlich (GitHub → *Packages* → `catalogservice` → *Package settings* →
  *Change visibility*). Prüfen auf einem Knoten: `sudo crictl pull ghcr.io/sschabbach-mse/catalogservice:0.1.0-create-api.1`.
- War `shop` vorher per Helm installiert: `helm -n shop uninstall shop` (keine Übernahme).

```bash
kubectl apply -f platform/argocd/apps/shop.yaml
kubectl -n argocd get application shop                 # SYNC STATUS Synced, HEALTH STATUS Healthy
kubectl -n shop get deploy,pods,svc,httproute
curl -s --resolve shop.k8s-lab:80:192.168.250.200 http://shop.k8s-lab/api/catalog/WeatherForecast
```

Hosts-Datei unter Windows ergänzen (`192.168.250.200  shop.k8s-lab`), dann im Browser
`http://shop.k8s-lab/api/catalog/WeatherForecast`.

**Neue Version eines Dienstes:** Tag in `products/shop/chart/values.yaml` ändern, committen, pushen. Argo CD
rollt die Änderung innerhalb weniger Minuten aus (sofort: *Refresh* in der Oberfläche). Änderungen direkt im
Cluster (`kubectl edit`, `helm upgrade`) setzt Argo CD zurück (`selfHeal`).

## Speicher: Optionen und Entscheidung

Anwendungen (Charts) fordern Speicher nur per PVC und **StorageClass-Name** an. Was dahintersteht, ist Sache
der Plattform – im Lab z. B. NFS, in Azure eine Managed Disk. So bleiben die Charts zwischen Lab und Cloud gleich.

**Dynamische Bereitstellung** (PVC → Volume entsteht automatisch) ist heute der Standard, z. B. in AKS/EKS/GKE.
Statisch (Administrator legt PVs vorab an) nutzt man gezielt, etwa für vorhandene Daten oder Speicher mit
eigenem Lebenszyklus. Auf die Leistung im Betrieb hat das keinen Einfluss; die hängt allein von der Art des
Speichers ab (lokal > Block-Disk > Netzwerkdateisystem).

**Größe:** Jedes PVC fordert eine Größe an. Bei Block-Disks ist sie eine harte Grenze, bei NFS und lokalen
Verzeichnissen nur eine Angabe. Grenzen pro Namespace setzt der Administrator mit `ResourceQuota` (Summe) und
`LimitRange` (pro PVC). Vergrößern geht, wenn die StorageClass `allowVolumeExpansion: true` erlaubt.

### Optionen im Lab

| Option | Art | Neu im Lab | Pod knotenunabhängig | Dynamisch | Für MongoDB | Cloud-Gegenstück |
|---|---|---|---|---|---|---|
| **NFS** (+ NFS-CSI-Treiber) | Datei, im Netz | NFS-VM, Treiber | ja | ja | zulässig, nicht empfohlen | Azure Files |
| **SMB vom Windows-Host** (+ SMB-CSI-Treiber) | Datei, im Netz | nur der Treiber, keine neue VM | ja | ja | ungeeignet | Azure Files (SMB) |
| **iSCSI** (Target-VM) | Block-Disk im Netz | iSCSI-VM, `open-iscsi` auf den Knoten; statisch ohne Treiber, dynamisch nur mit Community-Treiber | ja | statisch ja, dynamisch eingeschränkt | gut | Azure Managed Disk (am nächsten dran) |
| **Longhorn** | Block, über die Knoten repliziert | Longhorn im Cluster, `open-iscsi`, deutlich mehr RAM/Disk pro Knoten | ja | ja | gut | Azure Managed Disk |
| **Rook/Ceph** | Block, Datei, Objekt, verteilt | Ceph im Cluster, Rohdisks pro Knoten, ≥ 3 Knoten, viel RAM | ja | ja | gut | Managed Disk |
| **Lokal** (statisch `local` oder local-path-provisioner) | lokale Disk | nichts bzw. Provisioner | **nein** (`local` verlangt `nodeAffinity`) | nur local-path | gut (am schnellsten) | lokale Disk der VM |

Ein CSI-Treiber, der Hyper-V-Disks wie in Azure direkt an VMs hängt, ist nicht bekannt.

| Option | Einordnung |
|---|---|
| iSCSI | technisch am nächsten an einer Azure Managed Disk (Block-Disk, wird am Knoten des Pods angehängt); dynamisch nur über Community-Treiber; Server-VM als Einzelausfallpunkt |
| Longhorn | bildet das Cloud-Verhalten am vollständigsten nach, ohne zentralen Speicherserver; aber die schwerste realistische Option (2 GB RAM pro Worker eher knapp) |
| NFS | einfachster Weg zu dynamischem, knotenunabhängigem Speicher; Vorbehalt bei MongoDB |
| SMB | spart die VM, für Datenbanken die schlechteste Wahl |
| Rook/Ceph | für dieses Lab überdimensioniert |
| Lokal | widerspricht dem Ziel, dass Pods auf jedem Knoten laufen können |

### MongoDB auf NFS

Laut MongoDB-Produktionshinweisen dürfen WiredTiger-Dateien auf einem entfernten Dateisystem liegen, wenn es
POSIX-konform (ISO/IEC 9945) ist; die Performance kann darunter leiden. Empfohlene Mount-Optionen: `bg`, `hard`,
`nolock`, `noatime`, `nointr`. Die Produktions-Checkliste rät dagegen, NFS für den `dbPath` zu vermeiden
(„degraded and unstable performance“). Fazit: **zulässig, nicht empfohlen** – im Lab mit geringer Last vertretbar.
In Azure läge MongoDB auf einer Managed Disk; das Chart bleibt dasselbe.

Nebenbefund: MongoDB ist mit Linux-Kerneln 6.19 bis 7.0.13 inkompatibel und beendet sich dort beim Start.
Ubuntu 24.04 (Kernel 6.8) ist nicht betroffen – bei einem Kernel-Wechsel beachten.

### Entscheidung

**NFS mit dynamischer Bereitstellung** über den NFS-CSI-Treiber (`kubernetes-csi/csi-driver-nfs`, GA, aktuell
v4.13.6, Kubernetes ≥ 1.21). Der Treiber legt je PVC ein Unterverzeichnis auf dem NFS-Server an; nützliche
StorageClass-Parameter: `uid`/`gid` (Besitzer des Verzeichnisses, z. B. 999 für MongoDB) und `onDelete: retain`
(Verzeichnis bleibt beim Löschen des PVC erhalten).

Neu im Lab: eine NFS-Server-VM (`nfs-1`, eigene Daten-Disk) und der NFS-CSI-Treiber. Umsetzung: Schritt 19.

## Cluster neu aufbauen

Das Lab ist bewusst wegwerfbar: Alles, was die VMs und den Cluster ausmacht, steht im Repo. Der vollständige
Neuaufbau (Variante B, inkl. Plattform und Produkt) ist erfolgreich getestet. Dauer: geschätzt etwa 30 Minuten,
die meiste Zeit davon Paket- und Image-Downloads (nicht ohne Unterbrechungen gemessen).

**Bleibt beim Neuaufbau erhalten** (einmalige Einrichtung, siehe Schritte 1–3 und 5–6):

| Was | Wo |
|---|---|
| WinRM-Konfiguration | Windows-Host |
| Basis-Image | `base_image_path` |
| SSH-CA und Benutzerschlüssel | WSL `~/.ssh-ca`, `~/.ssh` |
| `terraform.tfvars`, Werkzeuge in WSL, `.wslconfig` | lokal |

**Wird neu erzeugt:** VMs, Disks, cloud-init-ISOs, Ansible-Inventory, Cluster (neue Zertifikate, neue
kubeconfig), Host-Schlüssel der VMs.

**Geht verloren** – es gibt bisher kein Backup:

| Was | Folge |
|---|---|
| Daten in MongoDB | neuer Cluster = neues PVC = neues, leeres Verzeichnis auf nfs-1. Bei Variante A liegt das alte Verzeichnis noch auf der Daten-Disk (`onDelete: retain`), wird aber nicht automatisch eingebunden |
| Passwörter (RabbitMQ, MongoDB, Dienste) | werden neu erzeugt; alle Secrets passen wieder zueinander. Würde man alte MongoDB-Daten einbinden, passten die dort gespeicherten Benutzer **nicht** zu den neuen Secrets |
| Nachrichten in RabbitMQ | ohnehin nicht persistent |
| Was nur von Hand im Cluster gemacht wurde | alles, was nicht in diesem Repo steht |

Die Images der Dienste liegen auf ghcr.io und sind nicht betroffen.

### Variante A: nur die VMs (empfohlen)

Switch und NAT bleiben stehen, keine Admin-Rechte nötig.

**Abbauen** (PowerShell, Ordner `terraform\hyper-v`):

```powershell
terraform destroy -target='hyperv_machine_instance.node' -target='hyperv_vhd.os' -target='hyperv_iso_image.cidata'
```

Die Daten-Disk von nfs-1 (`hyperv_vhd.data`) ist nicht im Ziel und bleibt erhalten – samt aller Volumes. Wird sie
nach dem Neuaufbau wieder eingebunden, formatiert `nfs-server.yml` sie nicht erneut (vorhandenes Dateisystem).
Weil der Cluster neu ist, bekommen neue PVCs trotzdem neue Verzeichnisse.

Terraform warnt bei `-target`, dass nur ein Teil abgebaut wird. Das ist hier gewollt.

### Variante B: alles inklusive Netzwerk

**Abbauen** (Admin-PowerShell, Ordner `terraform\hyper-v`, wegen des NAT-Skripts):

```powershell
terraform destroy
```

Entfernt VMs, Disks, ISOs, Inventory, Switch, Host-IP und NAT; das Basis-Image bleibt.
Für ein endgültiges Aufräumen zusätzlich den VM-Ordner (`vm_root`) und ggf. die Route bzw. Einträge in der
Hosts-Datei entfernen.

### Aufbauen (beide Varianten)

Bei Fehlern an der Stelle anhalten – jeder Schritt setzt den vorherigen voraus.

**1. Infrastruktur** (PowerShell, Ordner `terraform\hyper-v`; bei Variante B als **Admin**, weil das NAT-Skript läuft):

```powershell
..\host\Terraform-SetUserEnv.ps1
terraform apply              # Variante B: 16 to add
terraform plan               # erwartet: No changes
```

**2. Zugang** (WSL, Repo-Root) – die neuen VMs haben neue Host-Schlüssel unter denselben IPs, und
`StrictHostKeyChecking=accept-new` lehnt geänderte Schlüssel ab:

```bash
for ip in 192.168.250.11 192.168.250.12 192.168.250.13 192.168.250.20; do ssh-keygen -R "$ip"; done
eval "$(ssh-agent -s)" && bash ssh/sign-cert.sh -a
INV=ansible/inventory/hosts.yml
sleep 120                    # cloud-init braucht nach dem apply 1–2 Minuten
ansible -i $INV all -m ping  # alle 4 SUCCESS
```

**3. Knoten und Cluster** (WSL) – Reihenfolge beachten:

```bash
ansible-playbook -i $INV ansible/nfs-server.yml
ansible-playbook -i $INV ansible/prepare.yml
ansible-playbook -i $INV ansible/kubernetes.yml
ansible-playbook -i $INV ansible/control-plane.yml
bash platform/cilium/install.sh                     # inkl. IP-Pool
ansible-playbook -i $INV ansible/workers.yml
kubectl get nodes                                   # 3 Knoten Ready
```

Cilium kommt **vor** `workers.yml`: Ohne CNI wird kein Knoten `Ready`, und `workers.yml` wartet genau darauf.
Hubble Relay und UI bleiben bis zum Join der Worker `Pending`, weil die Control Plane per Taint für sie gesperrt
ist; danach starten sie von selbst. `control-plane.yml` überschreibt `~/.kube/k8s-lab.conf` mit der kubeconfig
des neuen Clusters.

**4. Plattform und Produkt** (WSL):

```bash
bash platform/envoy-gateway/install.sh
kubectl apply -f platform/gateway/gateway.yaml
bash platform/rabbitmq/install.sh
bash platform/nfs-csi/install.sh
bash platform/mongodb/install.sh
bash platform/argocd/install.sh
kubectl apply -f platform/argocd/apps/shop.yaml
```

**5. Prüfen**

```bash
kubectl get pods -A | grep -v -E "Running|Completed"     # nur die Kopfzeile
kubectl -n gateway get gateway lab                       # 192.168.250.200, PROGRAMMED True
kubectl -n argocd get application shop                   # Synced, Healthy
curl -s http://shop.k8s-lab/api/catalog/WeatherForecast  # JSON
```

Dazu im Browser `http://rabbitmq.k8s-lab` und `http://argocd.k8s-lab`. **Alle Passwörter sind neu:**

```bash
# RabbitMQ Management-UI (Benutzer admin)
kubectl -n rabbitmq get secret rabbitmq -o jsonpath='{.data.password}' | base64 -d; echo

# Argo CD (Benutzer admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# MongoDB-Administrator (Benutzer root), nur für Verwaltung
kubectl -n mongodb get secret mongodb -o jsonpath='{.data.root-password}' | base64 -d; echo

# Zugänge der Dienste (je Dienst ein Secret im Namespace shop)
kubectl -n shop get secrets -l app.kubernetes.io/component=client-credentials
kubectl -n shop get secret rabbitmq-catalog-api -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n shop get secret mongodb-catalog-api -o jsonpath='{.data.connection-string}' | base64 -d; echo
```

Die Route auf dem Windows-Host (`route -p`) und die Hosts-Datei bleiben über den Neuaufbau hinweg bestehen,
solange sich die IPs nicht ändern. Bei Variante B zeigt die Route zwischenzeitlich ins Leere; das ist unschädlich.

## Eigenheiten des Hyper-V-Providers

Der Provider `taliesins/hyperv` hat einige Fehler und Doku-Abweichungen. Die Konfiguration in `nodes.tf`
umgeht sie; die Kommentare dort verweisen hierher. Ermittelt aus dem Quelltext des Providers.

| Thema | Verhalten | Umgehung in `nodes.tf` |
|---|---|---|
| Differencing-Disk | `vhd_type` hat den Standard `Dynamic`; ohne `vhd_type = "Differencing"` legt der Provider eine leere Disk an und fordert eine Größe. Die Doku behauptet fälschlich, `vhd_type` und `parent_path` schlössen sich aus. | `vhd_type = "Differencing"` |
| Arbeitsspeicher | `static_memory` und `dynamic_memory` dürfen nicht beide gesetzt sein. | nur `static_memory = true` |
| ISO-Medientyp | `iso_media_type = "cdrom"` lehnt die Windows-Schnittstelle (IMAPI2) ab. | Standard des Providers verwenden |
| ZIP nach Fehlschlag | Scheitert die ISO-Erzeugung, bleibt `$env:TEMP\<vm>-cidata.zip` liegen, und der nächste Lauf meldet *already exists*. | Datei löschen, `apply` wiederholen |
| Warten auf IPs | `wait_for_ips` ist standardmäßig `true` (Timeout 300 s). Ohne KVP-Daemon in der VM wartet jeder Neuaufbau 5 Minuten. | `wait_for_ips = false` |
| Ressourcenpool | Hyper-V meldet `Primordial`; ohne Angabe entsteht ein Dauer-Diff. | `resource_pool_name = "Primordial"` an DVD und Netzwerkkarte |
| **Netzwerkkarte wird getrennt** | Das In-place-Update einer Netzwerkkarte vergleicht eine nicht existierende Eigenschaft (`ResourcePoolName` statt `PoolName`) und ruft dabei `Disconnect-VMNetworkAdapter` auf. Die VM ist danach nicht mehr erreichbar (*No route to host*). | `ignore_changes = [network_adaptors]`; Änderungen an der Karte nur per Neuaufbau |
| Boot-Reihenfolge | Hyper-V stellt die DVD wieder an erste Stelle, der Provider kann die Reihenfolge nicht halten. Unkritisch, die cloud-init-ISO ist nicht bootfähig. | `ignore_changes = [vm_firmware[0].boot_order]` |
| CPU-Einstellungen | Der Provider liest `vm_processor` mit hostabhängigen Werten aus und will sie ohne Konfiguration auf `null` setzen. | `ignore_changes = [vm_processor]` |

Eine VM gezielt neu bauen (z. B. für Änderungen an der Netzwerkkarte):

```powershell
terraform apply -replace='hyperv_machine_instance.node["cp-1"]'
```

Nach jedem `apply` sollte ein weiteres `terraform plan` **No changes** zeigen. Ist das nicht so, liegt ein
Dauer-Diff vor: vor dem nächsten `apply` prüfen, was der Provider ändern will.

## Netzwerk

| | |
|---|---|
| Switch | `k8s-lab` (Internal) |
| Subnetz | `192.168.250.0/24` |
| Gateway (Host) | `192.168.250.1` |
| NAT | `k8s-lab-nat` |
| Nodes | ab `192.168.250.11` (statisch per cloud-init) |
| NFS-Server | `nfs-1`: `192.168.250.20` |
| LoadBalancer-Pool | `192.168.250.200`–`207` (Cilium LB-IPAM), Gateway: `.200` |
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
| `ansible all -m ping` scheitert mit `Permission denied`, das Playbook funktioniert | `group_vars/` liegt neben dem Playbook statt neben dem Inventory. Ad-hoc-Befehle finden es dort nicht und verbinden sich als WSL-Benutzer statt als `ubuntu`. Richtig: `ansible/inventory/group_vars/all.yml` |
| `ansible: command not found`, aber `pipx` meldet *already seems to be installed* | `~/.local/bin` fehlt im `PATH`: `pipx ensurepath`, dann `exec bash` (*Werkzeuge in WSL*). Nicht `apt install ansible-core`. |
| `No inventory was parsed, only implicit localhost is available` | Kein Inventory angegeben: `-i ansible/inventory/hosts.yml` oder `ANSIBLE_INVENTORY` setzen (Schritt 9). Fehlt die Datei, mit `terraform apply` neu erzeugen. |
| Gateway-IP: `curl` läuft in einen Timeout, `kubectl get gateway` zeigt die Adresse | `externalTrafficPolicy: Local` am Envoy-Service, Envoy-Pod nicht auf `cp-1`. In der `EnvoyProxy`-Ressource `externalTrafficPolicy: Cluster` setzen (Schritt 17). Prüfen: `kubectl -n envoy-gateway-system get svc -o custom-columns=NAME:.metadata.name,POLICY:.spec.externalTrafficPolicy` |
| `Resolve-DnsName <name>.k8s-lab` liefert einen CNAME auf einen fremden Namen bzw. `127.0.0.1` | Eintrag wurde an die letzte Zeile der Hosts-Datei angehängt (Datei endete ohne Zeilenumbruch). Zeile als Administrator in zwei Zeilen aufteilen, `ipconfig /flushdns` |
| RabbitMQ in `CrashLoopBackOff`, Log: `Error when reading /var/lib/rabbitmq/.erlang.cookie: eacces` | Cookie wurde von einem root-Prozess angelegt (z. B. `rabbitmqctl` vor dem Broker). Einrichtung als Benutzer `rabbitmq` ausführen (`gosu`), siehe Schritt 18 |
| `ssh: connect to host … No route to host`, VM läuft | Netzwerkkarte vom Switch getrennt (siehe *Eigenheiten des Hyper-V-Providers*). Prüfen: `Get-VMNetworkAdapter -VMName cp-1`; wieder verbinden: `Connect-VMNetworkAdapter -VMName cp-1 -Name lab -SwitchName k8s-lab` |
| `ping` aus WSL: `Destination Host Unreachable` | VM aus (`Get-VM cp-1` in PowerShell, ggf. `Start-VM cp-1`) oder Netzwerkkarte getrennt (Zeile darüber). |
| `terraform plan` zeigt nach `apply` weiter Änderungen | Dauer-Diff durch den Provider, siehe *Eigenheiten des Hyper-V-Providers*. |
| `[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS` | Fakt über `ansible_…` gelesen. Stattdessen `ansible_facts['…']` (ohne Präfix). |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM wurde neu gebaut und hat einen neuen Host-Schlüssel. Alten Eintrag entfernen: `ssh-keygen -R 192.168.250.11` |
| VM nicht per SSH erreichbar | An der Hyper-V-Konsole anmelden (erfordert `console_password_hash`) und `cloud-init status --long` prüfen. |
| SSH: `Permission denied (publickey)` | Zertifikat abgelaufen oder falscher Principal: `ssh-keygen -L -f ~/.ssh/id_ed25519_k8s_lab-cert.pub` prüfen, ggf. neu signieren. |

## Ausblick

- [x] cloud-init Seed-ISO und erste VM (Gen2, Differencing-Disk), öffentlicher CA-Schlüssel per cloud-init
- [x] VMs per `for_each` aus `local.nodes`
- [x] `wait_for_ips = false` an der Netzwerkkarte
- [x] `terraform plan` nach `apply` zeigt No changes (Provider-Umgehungen greifen)
- [ ] Konsolen-Passwort wieder entfernen, sobald der Zertifikats-Zugang sich bewährt hat
- [ ] Ablageort des Basis-Images außerhalb des Repos
- [ ] Host-Zertifikate (VMs weisen sich per CA aus, kein Fingerprint-Wechsel nach Neuaufbau)
- [x] Ansible: Grundgerüst, Inventory aus Terraform
- [x] Ansible: Basis-Konfiguration (`prepare.yml`, Rolle `common`), idempotent
- [x] Ansible: containerd, Kubernetes-Pakete (`kubernetes.yml`)
- [x] Ansible: `kubeadm init` auf der Control Plane, kubeconfig nach WSL (`control-plane.yml`)
- [x] Helm: Cilium 1.20 als CNI (`platform/cilium`), Pod-Netzwerk mit kube-proxy
- [x] Cilium-Version zusammen mit der `values.yaml` im Repo festhalten (`install.sh`)
- [x] Hubble Relay und UI (Schritt 15)
- [x] Worker-Knoten (`kubeadm join`), danach Taint der Control Plane wieder setzen (Schritt 16)
- [ ] Neuaufbau in einem Durchgang (Skript bzw. `site.yml` für die Schritte nach `terraform apply`)
- [x] Entscheidung: kube-proxy bleibt vorerst (Option B)
- [x] LoadBalancer-IPs (Cilium LB-IPAM + statische Route) und Gateway API mit Envoy Gateway (Schritt 17)
- [ ] Option A (vorgemerkt): kube-proxy durch Cilium ersetzen – dann Cilium-Gateway und L2 Announcements statt Envoy Gateway und Route
- [ ] Hubble UI über das Gateway veröffentlichen (`hubble.k8s-lab`) statt per port-forward
- [ ] Terraform-Prüfung: keine VM-IP im LoadBalancer-Pool
- [x] RabbitMQ (eigenes Chart, Schritt 18), Management-UI unter `rabbitmq.k8s-lab`
- [x] Namespaces `shop`, `rabbitmq`, `mongodb`; Benutzer und Secrets pro Dienst (siehe *Namespaces*)
- [ ] Offen: Wo werden vhosts, Benutzer und Datenbanken eines Produkts definiert? Derzeit zentral in den
  Infrastruktur-Charts (`vhosts`/`clients` in `platform/rabbitmq/chart/values.yaml` und `platform/mongodb/chart/values.yaml`).
  Fachlich gehört das eher zum Chart der Anwendung (das Produkt kennt seine Dienste); dann bräuchte es einen Weg,
  wie das Produkt-Chart Zugänge anfordert, ohne Administratorrechte auf RabbitMQ/MongoDB zu haben.
  Bis dahin: Ein Eintrag in `clients` mit einem vhost, der in `vhosts` fehlt, lässt `setup.sh` abbrechen
  (nur im Log sichtbar) – optional eine Prüfung im Chart, die die Installation dann verweigert.
- [ ] RabbitMQ als Cluster mit 3 Knoten: Volumes aus `standard`, `worker-3`, Chart auf StatefulSet mit Peer Discovery, Erlang-Cookie, Anti-Affinity, PodDisruptionBudget
- [ ] Argo CD (Schritt 20); Produkt `shop` über Argo CD (Schritt 21), erster Dienst `catalogservice`; weitere Dienste (orders, Frontend) folgen
- [ ] Argo CD: Plattform-Komponenten übernehmen (vorher Passwörter ohne `lookup` lösen – Argo CD rendert Charts ohne Cluster-Zugriff, `lookup` liefert dort nichts); App-of-Apps statt einzelner `kubectl apply`
- [x] Neuaufbau in einem Durchgang getestet (Variante B, alle Schritte laut *Cluster neu aufbauen*)
- [ ] Neue VM-Namen
- [ ] Optional: App of Apps, damit nach Argo CD keine Application mehr von Hand angelegt werden muss
- [ ] catalogservice: Health-Endpunkt `/healthz` (dann `probe.type: http`), `UseHttpsRedirection` nur in Development, Routen mit gemeinsamem Präfix
- [x] NFS-Server `nfs-1`, NFS-CSI-Treiber, StorageClass `standard` und MongoDB 8.3 als Replica Set mit einem Mitglied (Schritt 19)
- [ ] catalog-api: Produkte in MongoDB statt In-Memory
- [ ] Zurückgestellt: RabbitMQ mit Persistenz bzw. als Cluster, MongoDB mit drei Mitgliedern, GitHub Actions für Images
- [ ] Argo CD (eigenes Repo `k8s-gitops`)
- [ ] RHEL-Image (Developer Subscription) als zweite Distribution
