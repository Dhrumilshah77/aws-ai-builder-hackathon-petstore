terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for workspaces"
  default     = "coder"
}

variable "pulumi_access_token" {
  type        = string
  description = "Pulumi Cloud access token for infrastructure management"
  sensitive   = true
  default     = ""
}

variable "launchdarkly_access_token" {
  type        = string
  description = "LaunchDarkly API key for feature flag management"
  sensitive   = true
  default     = ""
}

variable "anthropic_model" {
  type        = string
  description = "Anthropic model ID"
  default     = "us.anthropic.claude-sonnet-4-20250514-v1:0"
}

data "coder_parameter" "ai_prompt" {
  type        = "string"
  name        = "AI Prompt"
  icon        = "/emojis/1f4ac.png"
  description = "Initial task for Claude Code to execute"
  default     = "Build the AWS Pet Store Customer Support multi-agent system with order tracking, returns handling, and product recommendations using Pulumi for infrastructure and LaunchDarkly for feature flags"
  mutable     = true
}

data "coder_parameter" "cpu" {
  name         = "CPU Cores"
  type         = "number"
  description  = "CPU cores for the workspace"
  default      = 4
  mutable      = true
}

data "coder_parameter" "memory" {
  name         = "Memory (GB)"
  type         = "number"
  description  = "Memory allocation in GB"
  default      = 8
  mutable      = true
}

data "coder_parameter" "disk_size" {
  name         = "Disk Size (GB)"
  type         = "number"
  description  = "Persistent storage size"
  default      = 20
  mutable      = true
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  workspace_name = lower(data.coder_workspace.me.name)
  owner_name     = lower(data.coder_workspace_owner.me.name)
  home_folder    = "/home/coder"

  system_prompt = <<-EOT
    You are an AI assistant for the AWS Pet Store Support multi-agent project.
    You have access to Pulumi MCP Server for infrastructure as code and LaunchDarkly MCP Server for feature flag management.
    Use these tools to deploy infrastructure changes and manage feature flags for gradual rollouts.
    Always report task progress to Coder.
  EOT

  task_prompt = "Report initial task to Coder, then: ${data.coder_parameter.ai_prompt.value}"
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  startup_script = <<-EOT
    set -e
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs python3 python3-pip
    pip3 install --quiet fastapi uvicorn boto3 qdrant-client sentence-transformers httpx
    mkdir -p ${local.home_folder}/petstore-support
    echo "Workspace ready with Pulumi and LaunchDarkly MCP servers"
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage"
    key          = "memory"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

module "claude-code" {
  count         = data.coder_workspace.me.start_count
  source        = "registry.coder.com/coder/claude-code/coder"
  version       = "4.7.5"
  model         = var.anthropic_model
  agent_id      = coder_agent.main.id
  workdir       = local.home_folder
  subdomain     = false
  ai_prompt     = local.task_prompt
  system_prompt = local.system_prompt
  report_tasks  = true

  mcp = <<-EOF
  {
    "mcpServers": {
      "pulumi": {
        "headers": {
          "Authorization": "Bearer ${var.pulumi_access_token}"
        },
        "type": "http",
        "url": "https://mcp.ai.pulumi.com/mcp"
      },
      "LaunchDarkly": {
        "command": "npx",
        "args": [
          "-y", "--package", "@launchdarkly/mcp-server", "--", "mcp", "start",
          "--api-key", "${var.launchdarkly_access_token}"
        ]
      }
    }
  }
  EOF
}

resource "coder_ai_task" "claude-code" {
  count = data.coder_workspace.me.start_count
  sidebar_app {
    id = module.claude-code[0].task_app_id
  }
}

resource "coder_app" "petstore-support" {
  agent_id     = coder_agent.main.id
  slug         = "petstore-support"
  display_name = "Pet Store Support"
  icon         = "/icon/code.svg"
  url          = "http://localhost:3000"
  subdomain    = true

  healthcheck {
    url       = "http://localhost:3000"
    interval  = 5
    threshold = 3
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${local.owner_name}-${local.workspace_name}-home"
    namespace = var.namespace
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${local.owner_name}-${local.workspace_name}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "petstore-support-${local.workspace_name}"
    }
  }

  spec {
    security_context {
      run_as_user = 1000
      fs_group    = 1000
    }

    container {
      name              = "dev"
      image             = "codercom/enterprise-base:ubuntu"
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        run_as_user = 1000
      }

      resources {
        requests = {
          "cpu"    = "500m"
          "memory" = "500Mi"
        }
        limits = {
          "cpu"    = "${data.coder_parameter.cpu.value}"
          "memory" = "${data.coder_parameter.memory.value}Gi"
        }
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      volume_mount {
        mount_path = local.home_folder
        name       = "home"
        read_only  = false
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }
  }
}
