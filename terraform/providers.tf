provider "hyperv" {
  host     = "localhost"
  port     = 5985
  https    = false
  insecure = true
  use_ntlm = true
  user     = var.hyperv_user
  password = var.hyperv_password
  timeout  = "300s"
}
