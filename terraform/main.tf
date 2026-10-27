terraform {
  required_version = ">= 1.4.0"
}

variable "project_dir" {
  description = "Absolute path to the directory containing config.yml, setup-cluster.sh, scripts/, and k8s/node/helm/. Defaults to the parent of this terraform directory."
  type        = string
  default     = ""
}

variable "config_file" {
  description = "Config file used by the existing Canonical Kubernetes setup script."
  type        = string
  default     = "config.yml"
}

variable "setup_script" {
  description = "Existing Bash script that configures VPN and installs/joins Canonical Kubernetes."
  type        = string
  default     = "setup-cluster.sh"
}

variable "helm_deploy_script" {
  description = "Script that installs GAIE CRDs and deploys all Helm releases."
  type        = string
  default     = "scripts/deploy-helm.sh"
}

variable "llm_d_repo" {
  description = "Path to the llm-d checkout containing guides/env.sh. Defaults to <project_dir>/llm-d."
  type        = string
  default     = ""
}

variable "helm_dir" {
  description = "Path to the local Helm chart directory. Defaults to <project_dir>/k8s/node/helm."
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Required initial Grafana admin password for the observability chart. Supply via terraform.tfvars or TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.grafana_admin_password) >= 12
    error_message = "grafana_admin_password must be at least 12 characters."
  }
}

locals {
  resolved_project_dir = var.project_dir != "" ? abspath(var.project_dir) : abspath("${path.module}/..")
  resolved_config      = abspath("${local.resolved_project_dir}/${var.config_file}")
  resolved_script      = abspath("${local.resolved_project_dir}/${var.setup_script}")
  resolved_helm_script = abspath("${local.resolved_project_dir}/${var.helm_deploy_script}")
  resolved_llm_d_repo  = var.llm_d_repo != "" ? abspath(var.llm_d_repo) : abspath("${local.resolved_project_dir}/llm-d")
  resolved_helm_dir    = var.helm_dir != "" ? abspath(var.helm_dir) : abspath("${local.resolved_project_dir}/k8s/node/helm")
  chart_files          = fileset(local.resolved_helm_dir, "**")
  charts_hash          = sha256(join("", [for f in sort(local.chart_files) : filesha256("${local.resolved_helm_dir}/${f}")]))
}

resource "terraform_data" "kubernetes_setup" {
  # Replacing the setup script intentionally reruns node setup; config changes alone do not.
  triggers_replace = [filesha256(local.resolved_script)]
  input = {
    project_dir  = local.resolved_project_dir
    config_file  = local.resolved_config
    setup_script = local.resolved_script
    script_sha256 = filesha256(local.resolved_script)
  }

  provisioner "local-exec" {
    working_dir = local.resolved_project_dir
    interpreter = ["/bin/bash", "-c"]
    command     = "sudo -n bash '${local.resolved_script}' '${local.resolved_config}'"
  }
}

resource "terraform_data" "helm_deployment" {
  depends_on = [terraform_data.kubernetes_setup]

  # Changes to the deployment script or chart files replace this resource and rerun its provisioner.
  triggers_replace = [
    filesha256(local.resolved_helm_script),
    local.charts_hash,
    local.resolved_llm_d_repo,
    local.resolved_helm_dir,
  ]
  input = {
    config_file       = local.resolved_config
    deploy_script     = local.resolved_helm_script
    deploy_script_sha = filesha256(local.resolved_helm_script)
    charts_hash       = local.charts_hash
    llm_d_repo        = local.resolved_llm_d_repo
    helm_dir          = local.resolved_helm_dir
  }

  provisioner "local-exec" {
    working_dir = local.resolved_project_dir
    interpreter = ["/bin/bash", "-c"]
    command     = "sudo -n --preserve-env=GRAFANA_ADMIN_PASSWORD,LLM_D_REPO,HELM_DIR bash '${local.resolved_helm_script}' '${local.resolved_config}'"
    environment = {
      GRAFANA_ADMIN_PASSWORD = var.grafana_admin_password
      LLM_D_REPO             = local.resolved_llm_d_repo
      HELM_DIR               = local.resolved_helm_dir
    }
  }
}

output "project_dir" {
  value       = local.resolved_project_dir
  description = "Directory where the existing setup scripts were executed."
}

output "config_file" {
  value       = local.resolved_config
  description = "Configuration file passed to setup-cluster.sh and deploy-helm.sh."
}

output "helm_chart_dir" {
  value       = local.resolved_helm_dir
  description = "Directory containing the Helm charts installed by Terraform."
}
