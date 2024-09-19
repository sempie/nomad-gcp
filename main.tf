# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# Variables
variable "project_id" {
  description = "Google Cloud Project ID"
}

variable "region" {
  description = "Google Cloud region"
  default     = "us-east1"
}

variable "zone" {
  description = "Google Cloud zone"
  default     = "us-east1-b"
}

variable "cluster_name" {
  description = "Name of the cluster"
  default     = "hashicorp-cluster"
}

variable "node_count" {
  description = "Number of nodes in the cluster"
  default     = 3
}

variable "machine_type" {
  description = "Machine type for the nodes"
  default     = "e2-medium"
}

# Create a VPC network
resource "google_compute_network" "vpc_network" {
  name                    = "${var.cluster_name}-network"
  auto_create_subnetworks = false
}

# Create a subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.self_link
}

# Create firewall rules
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/24"]
}

resource "google_compute_firewall" "allow_external" {
  name    = "${var.cluster_name}-allow-external"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22", "4646", "8200", "8500"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# ... [Previous provider, variable, network, and firewall configurations remain the same]

# Create individual instances
resource "google_compute_instance" "hashicorp_node" {
  count        = var.node_count
  name         = "${var.cluster_name}-node-${count.index + 1}"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 100
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    access_config {
      // Ephemeral IP
    }
  }

  service_account {
    # https://developers.google.com/identity/protocols/googlescopes
    scopes = [
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/logging.write",
    ]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -e

    # Docker
    apt-get update
    apt-get install -y apt-transport-https ca-certificates gnupg2 
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update
    apt-get install -y docker-ce

    # Install HashiCorp tools
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
    apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    apt-get update
    apt-get install -y nomad consul vault jq

    # Get the instance's internal IP
    INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

    # Configure Consul
    cat <<EOT > /etc/consul.d/consul.hcl
    data_dir = "/opt/consul"
    client_addr = "0.0.0.0"
    server = true
    bootstrap_expect = ${var.node_count}
    retry_join = ["provider=gce project_name=${var.project_id} tag_value=${var.cluster_name}-node"]
    bind_addr = "$${INTERNAL_IP}"
    EOT

    # Configure Nomad
    cat <<EOT > /etc/nomad.d/nomad.hcl
    data_dir = "/opt/nomad"
    bind_addr = "0.0.0.0"
    server {
      enabled = true
      bootstrap_expect = ${var.node_count}
      server_join {
        retry_join = ["provider=gce project_name=${var.project_id} tag_value=${var.cluster_name}-node"]
      }
    }
    acl {
      enabled = true
    }
    client {
      enabled = true
    }
    consul {
      address = "127.0.0.1:8500"
    }
    advertise {
      http = "$${INTERNAL_IP}"
      rpc  = "$${INTERNAL_IP}"
      serf = "$${INTERNAL_IP}"
    }
    EOT

    # Configure Vault
    cat <<EOT > /etc/vault.d/vault.hcl
    storage "consul" {
      address = "127.0.0.1:8500"
      path    = "vault/"
    }
    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = 1
    }
    EOT

    # Start services
    systemctl enable consul nomad vault
    systemctl start consul nomad vault

    # Wait for Consul to be available
    until consul members; do
      echo "Waiting for Consul to start..."
      sleep 5
    done

    # Register Nomad service in Consul
    cat <<EOT > /etc/consul.d/nomad.json
    {
      "service": {
        "name": "nomad",
        "port": 4647,
        "check": {
          "name": "Nomad HTTP Check",
          "http": "http://localhost:4646/v1/agent/servers",
          "method": "GET",
          "interval": "10s",
          "timeout": "1s"
        }
      }
    }
    EOT

    consul reload

    # Wait for Nomad to be available
    until nomad server members; do
      echo "Waiting for Nomad to start..."
      sleep 5
    done

    echo "Setup complete"
  EOF

  tags = ["${var.cluster_name}-node"]

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  # Allow instance to be stopped/started
  allow_stopping_for_update = true
}

# Output
output "instance_ips" {
  value = google_compute_instance.hashicorp_node[*].network_interface[0].access_config[0].nat_ip
}
output "IP_Addresses" {
  value = <<CONFIGURATION

It will take a little bit for setup to complete and the UI to become available.
Once it is, you can access the Nomad UI at:

http://${google_compute_instance.hashicorp_node[0].network_interface.0.access_config.0.nat_ip}:4646/ui

Set the Nomad address, run the bootstrap, export the management token, set the token variable, and test connectivity:

export NOMAD_ADDR=http://${google_compute_instance.hashicorp_node[0].network_interface.0.access_config.0.nat_ip}:4646/ui && \
nomad acl bootstrap | grep -i secret | awk -F "=" '{print $2}' | xargs > nomad-management.token && \
export NOMAD_TOKEN=$(cat nomad-management.token) && \
nomad server members

Copy the token value and use it to log in to the UI:

cat nomad-management.token
CONFIGURATION
}