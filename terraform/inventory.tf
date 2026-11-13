locals {
  ansible_inventory = {
    all = {
      children = {
        control_plane = {
          hosts = { for name, n in local.nodes : name => { ansible_host = n.ip } if n.role == "control_plane" }
        }
        workers = {
          hosts = { for name, n in local.nodes : name => { ansible_host = n.ip } if n.role == "worker" }
        }
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content         = "# Generiert von terraform/inventory.tf - nicht von Hand bearbeiten.\n${yamlencode(local.ansible_inventory)}"

  lifecycle {
    precondition {
      condition     = alltrue([for n in values(local.nodes) : contains(["control_plane", "worker"], n.role)])
      error_message = "Jeder Eintrag in local.nodes braucht role = \"control_plane\" oder \"worker\"."
    }
  }
}
