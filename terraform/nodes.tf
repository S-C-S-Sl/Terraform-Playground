locals {
  nodes = {
    cp-1 = { ip = "192.168.250.11", cpus = 2, memory_gb = 4 }
  }

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
      hostname = each.key
    })
  }

  source {
    filename = "user-data"
    content = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
      hostname              = each.key
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
  path        = "${var.vm_root}\\${each.key}\\os.vhdx"
  parent_path = var.base_image_path
}

resource "hyperv_iso_image" "cidata" {
  for_each                  = local.nodes
  volume_name               = "CIDATA"
  source_zip_file_path      = data.archive_file.cidata[each.key].output_path
  source_zip_file_path_hash = data.archive_file.cidata[each.key].output_sha
  destination_iso_file_path = "${var.vm_root}\\${each.key}\\cidata.iso"
  iso_media_type            = "cdrom"
  iso_file_system_type      = "iso9660|joliet"

  depends_on = [hyperv_vhd.os] # legt den VM-Ordner an
}

# --- VM -------------------------------------------------------------------------
resource "hyperv_machine_instance" "node" {
  for_each = local.nodes

  name       = each.key
  path       = var.vm_root
  generation = 2
  notes      = "k8s-lab - verwaltet durch Terraform"

  processor_count      = each.value.cpus
  static_memory        = true
  dynamic_memory       = false
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
  }

  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.os[each.key].path
  }

  dvd_drives {
    controller_number   = 0
    controller_location = 1
    path                = hyperv_iso_image.cidata[each.key].destination_iso_file_path
  }

  # NAT muss stehen, bevor die VM Pakete laden will
  depends_on = [terraform_data.lab_nat]
}
