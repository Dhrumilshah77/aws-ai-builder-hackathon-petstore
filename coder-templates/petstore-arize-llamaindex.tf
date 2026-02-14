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

variable "arize_space_id" {
  type        = string
  description = "Arize Space ID for LLM observability"
  sensitive   = true
  default     = ""
}

variable "arize_api_key" {
  type        = string
  description = "Arize API Key for tracing"
  sensitive   = true
  default     = ""
}

variable "openai_api_key" {
  type        = string
  description = "OpenAI API Key for LlamaIndex"
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
  default     = "Build the AWS Pet Store Customer Support multi-agent system with LlamaIndex RAG for knowledge retrieval and Arize tracing for LLM observability"
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
    You have access to Arize MCP Server for LLM observability and tracing, and LlamaIndex MCP Server for RAG and document retrieval.
    Use these tools to trace LLM interactions, build knowledge bases, and implement RAG-powered customer support agents.
    Always report task progress to Coder.
  EOT

  task_prompt = "Report initial task to Coder, then: ${data.coder_parameter.ai_prompt.value}"
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    ARIZE_SPACE_ID = var.arize_space_id
    ARIZE_API_KEY  = var.arize_api_key
    OPENAI_API_KEY = var.openai_api_key
  }

  startup_script = <<-EOT
    set -e
    pip3 install --quiet llama-index llama-index-llms-openai llama-index-embeddings-openai arize-otel openinference-instrumentation-llama-index opentelemetry-sdk opentelemetry-exporter-otlp fastapi uvicorn boto3 qdrant-client sentence-transformers httpx uv
    mkdir -p ${local.home_folder}/petstore-support
    echo "Workspace ready with Arize and LlamaIndex MCP servers"
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

  metadata {
    display_name = "Arize Tracing"
    key          = "arize"
    script       = "[ -n \"$ARIZE_API_KEY\" ] && echo 'Enabled' || echo 'Disabled'"
    interval     = 30
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
      "arize-tracing-assistant": {
        "command": "uvx",
        "args": ["arize-mcp-server"],
        "env": {
          "ARIZE_SPACE_ID": "${var.arize_space_id}",
          "ARIZE_API_KEY": "${var.arize_api_key}"
        }
      },
      "llamaindex": {
        "command": "python3",
        "args": ["-m", "llama_index.tools.mcp.server"],
        "env": {
          "OPENAI_API_KEY": "${var.openai_api_key}"
        }
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
      "app.kubernetes.io/instance" = "petstore-support-arize-${local.workspace_name}"
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

      env {
        name  = "ARIZE_SPACE_ID"
        value = var.arize_space_id
      }

      env {
        name  = "ARIZE_API_KEY"
        value = var.arize_api_key
      }

      env {
        name  = "OPENAI_API_KEY"
        value = var.openai_api_key
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
