# Terraform-Playground – Kubernetes-Lab auf Hyper-V

Lokales Lab, um einen Kubernetes-Cluster auf Hyper-V aufzubauen.
Infrastruktur mit **Terraform** (Provider [`taliesins/hyperv`](https://registry.terraform.io/providers/taliesins/hyperv/latest)),
später Konfiguration mit **Ansible** und Cluster-Inhalte mit **Helm**.

> Status: Cluster mit drei Knoten (`cp-1`, `worker-1`, `worker-2`; Kubernetes 1.37, Cilium 1.20 mit Hubble) läuft
> und lässt sich jederzeit neu aufbauen. Als Nächstes: Entscheidung kube-proxy, LoadBalancer-IPs/Gateway API, Argo CD.

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
│   └── cilium/
│       ├── values.yaml           # CNI: Abweichungen von den Chart-Standardwerten
│       └── install.sh            # Chart-Version + Installation/Update
├── ansible/                      # Konfiguration der VMs (WSL)
│   ├── prepare.yml               # Playbook: Basis-Konfiguration aller VMs
│   ├── kubernetes.yml            # Playbook: containerd + Kubernetes-Pakete
│   ├── control-plane.yml         # Playbook: kubeadm init, kubeconfig nach WSL
│   ├── workers.yml               # Playbook: kubeadm join, Taint der Control Plane
│   ├── requirements.yml          # benötigte Collections
│   ├── roles/
│   │   ├── common/               # Updates, Grundpakete, Swap, Kernel-Module, sysctl
│   │   ├── containerd/           # Container-Runtime (systemd-cgroups)
│   │   ├── kubernetes/           # kubelet, kubeadm, kubectl aus pkgs.k8s.io, gesperrt
│   │   ├── control_plane/        # kubeadm-Konfiguration (Template), init, kubeconfig
│   │   └── worker/               # Join-Befehl erzeugen, kubeadm join, Label
│   └── inventory/
│       ├── hosts.yml             # von Terraform erzeugt, nicht eingecheckt
│       └── group_vars/all.yml    # Verbindung: Benutzer, Schlüssel, SSH-Optionen
└── terraform/                    # Lab-Ressourcen
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
| `terraform/` | Windows, Admin-PowerShell | Netz und VMs |

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

Die VMs selbst stehen in `terraform/nodes.tf` im Block `locals`:

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
| `inventory/hosts.yml` | Hosts und Gruppen, erzeugt von Terraform (`terraform/inventory.tf`) aus `local.nodes` in `nodes.tf` |
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

**1. VMs anlegen** – in `terraform/nodes.tf` die Worker in `local.nodes` eintragen bzw. einkommentieren:

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

## Cluster neu aufbauen

Das Lab ist bewusst wegwerfbar: Alles, was die VMs und den Cluster ausmacht, steht im Repo. Ein Neuaufbau
dauert etwa 15–20 Minuten, die meiste Zeit davon Paket-Downloads.

**Bleibt beim Neuaufbau erhalten** (einmalige Einrichtung, siehe Schritte 1–3 und 5–6):

| Was | Wo |
|---|---|
| WinRM-Konfiguration | Windows-Host |
| Basis-Image | `base_image_path` |
| SSH-CA und Benutzerschlüssel | WSL `~/.ssh-ca`, `~/.ssh` |
| `terraform.tfvars`, Werkzeuge in WSL, `.wslconfig` | lokal |

**Wird neu erzeugt:** VMs, Disks, cloud-init-ISOs, Ansible-Inventory, Cluster (neue Zertifikate, neue
kubeconfig), Host-Schlüssel der VMs.

### Variante A: nur die VMs (empfohlen)

Switch und NAT bleiben stehen, keine Admin-Rechte nötig.

**Abbauen** (PowerShell, Ordner `terraform`):

```powershell
terraform destroy -target='hyperv_machine_instance.node' -target='hyperv_vhd.os' -target='hyperv_iso_image.cidata'
```

Terraform warnt bei `-target`, dass nur ein Teil abgebaut wird. Das ist hier gewollt.

### Variante B: alles inklusive Netzwerk

**Abbauen** (Admin-PowerShell, Ordner `terraform`, wegen des NAT-Skripts):

```powershell
terraform destroy
```

Entfernt VMs, Disks, ISOs, Inventory, Switch, Host-IP und NAT; das Basis-Image bleibt.
Für ein endgültiges Aufräumen zusätzlich den VM-Ordner (`vm_root`) und ggf. die Route bzw. Einträge in der
Hosts-Datei entfernen.

### Aufbauen (beide Varianten)

**1. Infrastruktur** (PowerShell, Ordner `terraform`; bei Variante B als Admin):

```powershell
..\host\Terraform-SetUserEnv.ps1
terraform apply
terraform plan       # erwartet: No changes
```

**2. Alte Host-Schlüssel entfernen** (WSL) – die neuen VMs haben neue Schlüssel unter denselben IPs, und
`StrictHostKeyChecking=accept-new` lehnt geänderte Schlüssel ab:

```bash
for ip in 192.168.250.11 192.168.250.12 192.168.250.13; do ssh-keygen -R "$ip"; done
```

**3. Zertifikat** (falls abgelaufen) und warten, bis cloud-init fertig ist (1–2 Minuten nach dem `apply`):

```bash
cd /mnt/c/<pfad-zum-repo>
eval "$(ssh-agent -s)" && bash ssh/sign-cert.sh -a
INV=ansible/inventory/hosts.yml
ansible -i $INV all -m ping
```

**4. Cluster aufbauen – Reihenfolge beachten:**

```bash
ansible-playbook -i $INV ansible/prepare.yml
ansible-playbook -i $INV ansible/kubernetes.yml
ansible-playbook -i $INV ansible/control-plane.yml
bash platform/cilium/install.sh
ansible-playbook -i $INV ansible/workers.yml
kubectl get nodes -o wide
```

Cilium kommt **vor** `workers.yml`: Ohne CNI wird kein Knoten `Ready`, und `workers.yml` wartet genau darauf.
Hubble Relay und UI bleiben bis zum Join der Worker `Pending`, weil die Control Plane per Taint für sie gesperrt
ist; danach starten sie von selbst. Ein Entfernen des Taints wie in Schritt 14 ist mit Workern nicht nötig.

`control-plane.yml` überschreibt `~/.kube/k8s-lab.conf` mit der kubeconfig des neuen Clusters.

**5. Prüfen**

```bash
kubectl get nodes                           # 3 Knoten Ready
kubectl get pods -A                         # alles Running
```

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
- [ ] **Entscheidung offen:** kube-proxy behalten oder durch Cilium ersetzen (L2 Announcements für LoadBalancer-IPs setzen den Ersatz voraus)
- [ ] LoadBalancer-IPs und Gateway API (vorerst über eine statische Route auf dem Windows-Host)
- [ ] Argo CD (eigenes Repo `k8s-gitops`)
- [ ] RHEL-Image (Developer Subscription) als zweite Distribution
