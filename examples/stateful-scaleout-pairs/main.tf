terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.8"
    }
  }
}

data "google_compute_subnetwork" "external" {
  self_link = var.interfaces[0].subnet_id
}

data "google_compute_subnetwork" "management" {
  self_link = var.interfaces[1].subnet_id
}

provider "google" {
  # Apply a consistent set of labels to all resources that accept labels.
  default_labels = merge({
    module   = "terraform-google-f5-bigip-ha"
    scenario = "stateful-scaleout-pairs"
  }, var.labels == null ? {} : var.labels)
}

locals {
  # Map logical pair identifiers ("pair-01", "pair-02", ...) to RFC1035 resource prefixes ("<name>-p01", "<name>-p02", ...)
  pairs = {
    for i in range(1, var.num_pairs + 1) :
    format("pair-%02d", i) => format("%s-p%02d", var.name, i)
  }

  # Flatten per-pair zonal instance groups for GCE_VM_IP NEGs
  pair_negs = merge([
    for pair_key, pair_prefix in local.pairs : {
      for zone, _ in module.bigip_ha[pair_key].instances_by_zone :
      format("%s/%s", pair_key, zone) => {
        pair_key    = pair_key
        pair_prefix = pair_prefix
        zone        = zone
      }
    }
  ]...)

  # Flatten per-pair network endpoints for registration in zonal GCE_VM_IP NEGs
  pair_endpoints = merge([
    for pair_key, _ in local.pairs : {
      for inst_name, ep in module.bigip_ha[pair_key].network_endpoints :
      inst_name => {
        pair_key   = pair_key
        neg_key    = format("%s/%s", pair_key, ep.zone)
        instance   = ep.instance
        ip_address = ep.ip_address
        zone       = ep.zone
      }
    }
  ]...)
}

# Reserve a public IPv4 address for each HA pair that will be assigned to that pair's Google Cloud NLB forwarding-rule
# and used as the virtual address in the BIG-IP service.
resource "google_compute_address" "vip" {
  for_each     = local.pairs
  project      = var.project_id
  name         = each.value
  description  = <<-EOD
    An example external public address for ${each.key} in stateful-scaleout-pairs example.
    EOD
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  network_tier = "PREMIUM"
  region       = var.region
}

# The module requires an explicit service account; this could be an existing SA such as the default compute service
# account, but the recommendation is to create a service account just for the BIG-IP workloads.
resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = var.name
  display_name = "BIG-IP Service Account for stateful-scaleout-pairs example scenario"
  description  = <<-EOD
    An example service account for stateful-scaleout-pairs example; this scenario does not require that the VMs have
    access to Google Cloud APIs, so it will not be bound to any permissions.
    EOD
  # NOTE: Setting this to true to support rapid iteration when testing
  create_ignore_already_exists = true
}

# Generate a random password for the BIG-IP administration.
resource "random_string" "admin_password" {
  length      = 16
  upper       = true
  min_upper   = 2
  lower       = true
  min_lower   = 2
  numeric     = true
  min_numeric = 2
  special     = true
  min_special = 2
  # Set the default set of special characters to those listed in https://my.f5.com/manage/s/article/K2873, excluding all
  # forms of quotation, apostrophe and backslash to avoid potential issues when quoting the string.
  override_special = "!$%^&*()~-+=[]{}:./<>|"
}

# Create a Secret Manager secret with random password for BIG-IP access. The BIG-IP service account will be permitted to
# retrieve the password.
module "admin_password" {
  source     = "memes/secret-manager/google"
  version    = "2.2.2"
  project_id = var.project_id
  id         = var.name
  secret     = null
  accessors = [
    google_service_account.sa.member,
  ]

  depends_on = [
    google_service_account.sa,
  ]
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = module.admin_password.id
  secret_data = random_string.admin_password.result

  depends_on = [
    module.admin_password,
    random_string.admin_password,
  ]
}

# Deploy N independent BIG-IP active-standby HA pairs.
module "bigip_ha" {
  for_each   = local.pairs
  source     = "git::https://github.com/f5devcentral/terraform-google-f5-bigip-ha?ref=v0.2.3"
  project_id = var.project_id
  prefix     = each.value
  # For consistent and predictable naming, it is important to set the common DNS domain name to use with instances; for
  # example 'your-domain.com'. Instances will be given the host name "{prefix}-0n.{host_domain}".
  # NOTE: BIG-IP hostnames have a limit of 65 characters.
  host_domain     = "example.com"
  description     = <<-EOD
  An example BIG-IP active-standby HA deployment (${each.key}) for stateful-scaleout-pairs scenario.
  EOD
  service_account = google_service_account.sa.email
  interfaces      = var.interfaces
  metadata        = var.metadata
  # This example builds a runtime-init configuration from a template file, substituting values as needed. For production
  # deployments this will most likely be a static file with lifecycle managed outside this module.
  runtime_init_config = templatefile(format("%s/templates/runtime-init-conf.yaml", path.module), {
    admin_pass_secret = module.admin_password.secret_id
    vip               = google_compute_address.vip[each.key].address
  })

  depends_on = [
    google_compute_address.vip,
    module.admin_password,
  ]
}

# Create a zonal GCE_VM_IP Network Endpoint Group in each zone for each HA pair.
resource "google_compute_network_endpoint_group" "bigip" {
  for_each              = local.pair_negs
  project               = var.project_id
  name                  = format("%s-%s", each.value.pair_prefix, each.value.zone)
  description           = <<-EOD
    F5 BIG-IP GCE_VM_IP network endpoint group for VEs in ${each.value.pair_key} of stateful-scaleout-pairs example.
    EOD
  network               = data.google_compute_subnetwork.external.network
  subnetwork            = data.google_compute_subnetwork.external.self_link
  network_endpoint_type = "GCE_VM_IP"
  zone                  = each.value.zone

  depends_on = [
    module.bigip_ha,
  ]
}

# Register each BIG-IP instance's primary data-plane interface (nic0) in its pair's zonal GCE_VM_IP NEG.
resource "google_compute_network_endpoint" "bigip" {
  for_each               = local.pair_endpoints
  project                = var.project_id
  network_endpoint_group = google_compute_network_endpoint_group.bigip[each.value.neg_key].name
  instance               = each.value.instance
  ip_address             = each.value.ip_address
  zone                   = each.value.zone

  depends_on = [
    google_compute_network_endpoint_group.bigip,
  ]
}

# Create a regional passthrough Network Load Balancer backend service per HA pair configured for GARP/RA fast IP move.
# No health check is configured because ha_policy steers all connections exclusively to the active leader endpoint in
# each pair, updating leadership sub-second when the newly active BIG-IP emits a Gratuitous ARP (GARP) for the VIP.
resource "google_compute_region_backend_service" "bigip" {
  for_each              = local.pairs
  project               = var.project_id
  name                  = each.value
  description           = <<-EOD
    F5 BIG-IP regional backend service with GARP_RA HA policy for ${each.key} in stateful-scaleout-pairs example.
    EOD
  region                = var.region
  load_balancing_scheme = "EXTERNAL"
  protocol              = "TCP"
  network               = data.google_compute_subnetwork.external.network

  dynamic "backend" {
    for_each = {
      for k, v in google_compute_network_endpoint_group.bigip : k => v
      if local.pair_negs[k].pair_key == each.key
    }
    content {
      balancing_mode = "CONNECTION"
      group          = backend.value.self_link
    }
  }

  ha_policy {
    fast_ip_move = "GARP_RA"
    leader {
      backend_group = google_compute_network_endpoint_group.bigip[format("%s/%s", each.key, module.bigip_ha[each.key].network_endpoints[module.bigip_ha[each.key].names[0]].zone)].self_link
      network_endpoint {
        instance = module.bigip_ha[each.key].names[0]
      }
    }
  }

  lifecycle {
    # Ignore runtime leader changes triggered by BIG-IP GARP failover announcements.
    ignore_changes = [
      ha_policy[0].leader,
    ]
  }

  depends_on = [
    google_compute_network_endpoint.bigip,
  ]
}

resource "google_compute_forwarding_rule" "vip" {
  for_each              = local.pairs
  project               = var.project_id
  name                  = each.value
  description           = <<-EOD
    An example forwarding-rule that sends all TCP traffic for ${each.key} to that pair's BIG-IP backend service.
    EOD
  region                = var.region
  backend_service       = google_compute_region_backend_service.bigip[each.key].id
  ip_address            = google_compute_address.vip[each.key].id
  ip_protocol           = "TCP"
  ip_version            = "IPV4"
  all_ports             = true
  load_balancing_scheme = "EXTERNAL"

  depends_on = [
    google_compute_region_backend_service.bigip,
  ]
}

# By default, Google Cloud imposes a default DENY ingress rule; to allow BIG-IP instances to receive traffic from the
# public internet it must allow ingress from they must be allowed to connect to the VMs.
resource "google_compute_firewall" "public" {
  project       = var.project_id
  name          = format("%s-allow-bigip-ext", var.name)
  network       = data.google_compute_subnetwork.external.network
  description   = "Allow access to BIG-IP from sources on the internet"
  direction     = "INGRESS"
  source_ranges = coalescelist(var.allowlist_cidrs == null ? [] : var.allowlist_cidrs, ["0.0.0.0/0"])
  target_service_accounts = [
    google_service_account.sa.email,
  ]
  allow {
    protocol = "tcp"
    ports = [
      80,
      443,
    ]
  }
}

# By default, Google Cloud imposes a default DENY ingress rule; to allow access to BIG-IP management console from public
# sources or private addresses routed via jumphost or VPC.
resource "google_compute_firewall" "mgmt" {
  for_each      = try(length(var.mgmt_allowlist_cidrs), 0) > 0 ? { sources = var.mgmt_allowlist_cidrs } : {}
  project       = var.project_id
  name          = format("%s-allow-bigip-mgmt", var.name)
  network       = data.google_compute_subnetwork.management.network
  description   = "Allow management access to BIG-IP from given sources"
  direction     = "INGRESS"
  source_ranges = each.value
  target_service_accounts = [
    google_service_account.sa.email,
  ]
  allow {
    protocol = "tcp"
    ports = [
      22,
      443,
    ]
  }
}
