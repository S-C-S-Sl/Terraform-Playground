resource "hyperv_network_switch" "lab" {
  name        = "k8s-lab"
  switch_type = "Internal"
  notes       = "Kubernetes Lab - verwaltet durch Terraform"
}

locals {
  lab_net = {
    switch_name   = hyperv_network_switch.lab.name
    gateway_ip    = "192.168.250.1"
    prefix_length = 24
    nat_prefix    = "192.168.250.0/24"
    nat_name      = "k8s-lab-nat"
  }
}

resource "terraform_data" "lab_nat" {
  input            = merge(local.lab_net, { scripts_dir = "${path.module}/../../host" })
  triggers_replace = local.lab_net

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "& '${self.input.scripts_dir}/setup-nat.ps1' -SwitchName '${self.input.switch_name}' -GatewayIp '${self.input.gateway_ip}' -PrefixLength ${self.input.prefix_length} -NatPrefix '${self.input.nat_prefix}' -NatName '${self.input.nat_name}'"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "& '${self.input.scripts_dir}/teardown-nat.ps1' -SwitchName '${self.input.switch_name}' -GatewayIp '${self.input.gateway_ip}' -NatName '${self.input.nat_name}'"
  }
}
