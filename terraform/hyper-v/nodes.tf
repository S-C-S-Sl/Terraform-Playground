locals {
  nodes = {
    cp-1 = {  role = "control_plane", ip = "192.168.250.11", cpus = 2, memory_gb = 4 },
    worker-1 = { role = "worker", ip = "192.168.250.12", cpus = 2, memory_gb = 2 },
    worker-2 = { role = "worker", ip = "192.168.250.13", cpus = 2, memory_gb = 2 },
    nfs-1    = { role = "nfs", ip = "192.168.250.20", cpus = 1, memory_gb = 1 },
  }

  # Zusätzliche Daten-Disk (GB) je VM. Eigene Terraform-Ressource, damit ein Neuaufbau
  # der VM (Betriebssystem-Disk) die Daten nicht löscht.
  data_disks = {
    nfs-1 = 50
  }

  # Name einer VM: Prefix + Key. Gilt für Hyper-V-Name, Ordner, Hostname (= Knotenname im Cluster)
  # und Ansible-Inventory. Der Key selbst bleibt der Schlüssel in local.nodes und local.data_disks.
  vm_names = { for key, node in local.nodes : key => "${var.resource_prefix}${key}" }

  lab_prefix_length = local.lab_net.prefix_length
  lab_gateway       = local.lab_net.gateway_ip
}
# --- cloud-init Seed (NoCloud) ------------------------------------------------
# Die drei Dateien werden lokal gezippt, der Provider baut daraus auf dem Host
# eine ISO. cloud-init erkennt sie am Volume-Namen CIDATA.
data "archive_file" "cidata" {
  for_each    = local.nodes
  type        = "zip"
  output_path = "${path.module}/.build/${each.key}-cidata.zip"

  source {
    filename = "meta-data"
    content = templatefile("${path.module}/templates/meta-data.yaml.tftpl", {
      hostname = local.vm_names[each.key]
    })
  }

  source {
    filename = "user-data"
    content = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
      hostname              = local.vm_names[each.key]
      ssh_ca_public_key     = trimspace(var.ssh_user_ca_public_key)
      console_password_hash = var.console_password_hash
    })
  }

  source {
    filename = "network-config"
    content = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
      ip            = each.value.ip
      prefix_length = local.lab_prefix_length
      gateway       = local.lab_gateway
      dns_servers   = var.dns_servers
    })
  }
}

# --- OS-Disk: Differencing-Disk auf dem Basis-Image -------------------------
resource "hyperv_vhd" "os" {
  for_each    = local.nodes
  path        = "${var.vm_root}\\${local.vm_names[each.key]}\\os.vhdx"
  parent_path = var.base_image_path
  vhd_type    = "Differencing" # Pflicht, sonst legt der Provider eine leere Disk an (Doku ist hier falsch)
}

# --- Daten-Disk (dynamisch wachsend, leer; Ansible legt das Dateisystem an) ---
resource "hyperv_vhd" "data" {
  for_each = local.data_disks
  path     = "${var.vm_root}\\${local.vm_names[each.key]}\\data.vhdx"
  vhd_type = "Dynamic"
  size     = each.value * 1024 * 1024 * 1024

  depends_on = [hyperv_vhd.os] # legt den VM-Ordner an
}

resource "hyperv_iso_image" "cidata" {
  for_each                  = local.nodes
  volume_name               = "CIDATA"
  source_zip_file_path      = data.archive_file.cidata[each.key].output_path
  source_zip_file_path_hash = data.archive_file.cidata[each.key].output_sha
  destination_iso_file_path = "${var.vm_root}\\${local.vm_names[each.key]}\\cidata.iso"
  iso_file_system_type      = "iso9660|joliet"

  depends_on = [hyperv_vhd.os] # legt den VM-Ordner an
}

# --- VM -------------------------------------------------------------------------
resource "hyperv_machine_instance" "node" {
  for_each = local.nodes

  name       = local.vm_names[each.key]
  path       = var.vm_root
  generation = 2
  notes      = "k8s-lab - verwaltet durch Terraform"

  processor_count      = each.value.cpus
  static_memory        = true # schließt dynamic_memory aus
  memory_startup_bytes = each.value.memory_gb * 1024 * 1024 * 1024

  checkpoint_type        = "Disabled" # Checkpoints vertragen sich schlecht mit Differencing-Disks
  automatic_start_action = "Nothing"
  automatic_stop_action  = "ShutDown"
  state                  = "Running"

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftUEFICertificateAuthority" # nötig für Linux
    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }
  }

  integration_services = {
    "Guest Service Interface" = false
    "Heartbeat"               = true
    "Key-Value Pair Exchange" = true
    "Shutdown"                = true
    "Time Synchronization"    = true
    "VSS"                     = true
  }

  network_adaptors {
    name        = "lab"
    switch_name = hyperv_network_switch.lab.name
    wait_for_ips = false
    resource_pool_name = "Primordial"
  }

  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.os[each.key].path
  }

  # Daten-Disk nur für VMs aus local.data_disks; in der VM als /dev/sdb sichtbar
  # (Position 1 belegt das DVD-Laufwerk mit der cloud-init-ISO)
  dynamic "hard_disk_drives" {
    for_each = contains(keys(local.data_disks), each.key) ? [hyperv_vhd.data[each.key].path] : []
    content {
      controller_type     = "Scsi"
      controller_number   = 0
      controller_location = 2
      path                = hard_disk_drives.value
    }
  }

  dvd_drives {
    resource_pool_name  = "Primordial"
    controller_number   = 0
    controller_location = 1
    path                = hyperv_iso_image.cidata[each.key].destination_iso_file_path
  }


  lifecycle {
    # Umgehungen für Provider-Fehler, siehe README "Eigenheiten des Hyper-V-Providers"
    ignore_changes = [vm_processor, network_adaptors, vm_firmware[0].boot_order]
  }

  # NAT muss stehen, bevor die VM Pakete laden will
  depends_on = [terraform_data.lab_nat]
}
