# --- Zugang Hyper-V (über TF_VAR_* aus host/Terraform-SetUserEnv.ps1) -------
variable "hyperv_user" {
  type = string
}

variable "hyperv_password" {
  type      = string
  sensitive = true
}

# --- Ablage -----------------------------------------------------------------
variable "base_image_path" {
  type        = string
  description = "Schreibgeschütztes Basis-Image (aus base-image/prepare-image.sh)"
  default     = "D:\\Hyper-V\\images\\ubuntu-2404-base.vhdx"
}

variable "vm_root" {
  type        = string
  description = "Ordner, unter dem pro VM ein Unterordner angelegt wird"
  default     = "D:\\Hyper-V\\VMs"
}

# --- Netz -------------------------------------------------------------------
variable "dns_servers" {
  type        = list(string)
  description = "DNS-Server der VMs (die des Hosts: Get-DnsClientServerAddress)"
}

# --- Zugang zu den VMs --------------------------------------------------------
variable "ssh_user_ca_public_key" {
  type        = string
  description = "Inhalt von ~/.ssh-ca/<ca>.pub (WSL). Nur der öffentliche Teil!"
}

variable "console_password_hash" {
  type        = string
  description = "Optional: SHA-512-Hash (mkpasswd -m sha-512) für Login an der Hyper-V-Konsole. null = kein Passwort."
  default     = null
  sensitive   = true
}
