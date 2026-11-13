output "ssh" {
  description = "Login aus WSL (Zertifikat vorher mit ssh/sign-cert.sh ausstellen)"
  value = {
    for name, node in local.nodes :
    name => "ssh -i ~/.ssh/id_ed25519_k8s_lab ubuntu@${node.ip}"
  }
}
