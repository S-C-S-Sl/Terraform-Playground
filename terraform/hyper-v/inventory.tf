# Gruppen ergeben sich aus role: control_plane und workers bilden zusammen "k8s",
# nfs ist eine eigene Gruppe (kein Kubernetes auf dem NFS-Server).
locals {
  ansible_inventory = {
    all = {
      children = {
        k8s = {
          children = {
            control_plane = {
              hosts = { for name, n in local.nodes : local.node_names[name] => { ansible_host = n.ip } if n.role == "control_plane" }
            }
            workers = {
              hosts = { for name, n in local.nodes : local.node_names[name] => { ansible_host = n.ip } if n.role == "worker" }
            }
          }
        }
        nfs = {
          hosts = { for name, n in local.nodes : local.node_names[name] => { ansible_host = n.ip } if n.role == "nfs" }
        }
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content         = "# Generiert von terraform/hyper-v/inventory.tf - nicht von Hand bearbeiten.\n${yamlencode(local.ansible_inventory)}"

  lifecycle {
    precondition {
      condition     = alltrue([for n in values(local.nodes) : contains(["control_plane", "worker", "nfs"], n.role)])
      error_message = "Jeder Eintrag in local.nodes braucht role = \"control_plane\", \"worker\" oder \"nfs\"."
    }
  }
}
