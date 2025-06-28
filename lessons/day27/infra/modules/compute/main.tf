/*
 * Compute Module
 * This module creates either frontend or backend compute resources with:
 * - VM Scale Set for application hosting
 * - Load balancer (Application Gateway for frontend, internal LB for backend)
 * - Managed identity for secure authentication
 * - Custom data script for Docker container setup
 */

locals {
  # Determine tier name based on frontend/backend flag
  tier_name     = var.is_frontend ? "frontend" : "backend"
  tier_priority = var.is_frontend ? 100 : 200

  # Full image name (Docker Hub)
  full_image_name = var.docker_image

  # Path to provisioning scripts
  frontend_script_path = "${path.module}/scripts/frontend_provision.sh"
  backend_script_path  = "${path.module}/scripts/backend_provision.sh"
}

# Generate provisioning script with variable substitution using templatefile()
locals {
  # Generate the provisioning script content with variable substitution
  provisioning_script_content = var.is_frontend ? templatefile(local.frontend_script_path, {
    # Frontend script variables
    user_assigned_identity_id = azurerm_user_assigned_identity.vmss_identity.id
    dockerhub_username        = var.dockerhub_username
    dockerhub_password        = var.dockerhub_password
    application_port          = var.application_port
    full_image_name           = local.full_image_name
    backend_lb_ip             = var.backend_load_balancer_ip
    }) : templatefile(local.backend_script_path, {
    # Backend script variables
    user_assigned_identity_id = azurerm_user_assigned_identity.vmss_identity.id
    dockerhub_username        = var.dockerhub_username
    dockerhub_password        = var.dockerhub_password
    application_port          = var.application_port
    full_image_name           = local.full_image_name
    key_vault_id              = var.key_vault_id
    db_host                   = var.database_connection.host
    db_port                   = var.database_connection.port
    db_username               = var.database_connection.username
    db_password               = var.database_connection.password
    db_name                   = var.database_connection.dbname
    db_sslmode                = var.database_connection.sslmode
  })
}

# VM SSH Key for Admin Access
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Public IP for Load Balancer (Frontend only)
resource "azurerm_public_ip" "lb" {
  count               = var.is_frontend ? 1 : 0
  name                = "${var.resource_name_prefix}-${local.tier_name}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Application Gateway for Frontend
resource "azurerm_application_gateway" "frontend" {
  count               = var.is_frontend ? 1 : 0
  name                = "${var.resource_name_prefix}-appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = var.appgw_subnet_id != null ? var.appgw_subnet_id : var.subnet_id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.lb[0].id
  }

  backend_address_pool {
    name = "backend-pool"
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = var.application_port
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "health-probe"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 1
  }

  probe {
    name                = "health-probe"
    host                = "127.0.0.1"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    protocol            = "Http"
    port                = var.application_port
    path                = var.health_probe_path
  }

  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }
}

# Internal Load Balancer for Backend
resource "azurerm_lb" "backend" {
  count               = var.is_frontend ? 0 : 1
  name                = "${var.resource_name_prefix}-${local.tier_name}-lb"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "internal-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "backend" {
  count           = var.is_frontend ? 0 : 1
  name            = "${var.resource_name_prefix}-${local.tier_name}-backend-pool"
  loadbalancer_id = azurerm_lb.backend[0].id
}

resource "azurerm_lb_probe" "backend" {
  count               = var.is_frontend ? 0 : 1
  name                = "${var.resource_name_prefix}-${local.tier_name}-probe"
  loadbalancer_id     = azurerm_lb.backend[0].id
  protocol            = "Http"
  port                = var.application_port
  request_path        = var.health_probe_path
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "backend" {
  count                          = var.is_frontend ? 0 : 1
  name                           = "${var.resource_name_prefix}-${local.tier_name}-rule"
  loadbalancer_id                = azurerm_lb.backend[0].id
  protocol                       = "Tcp"
  frontend_port                  = var.application_port
  backend_port                   = var.application_port
  frontend_ip_configuration_name = "internal-ip-config"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend[0].id]
  probe_id                       = azurerm_lb_probe.backend[0].id
}

# User-assigned Managed Identity for VM Scale Set
resource "azurerm_user_assigned_identity" "vmss_identity" {
  name                = "${var.resource_name_prefix}-${local.tier_name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# VM Scale Set
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "${var.resource_name_prefix}-${local.tier_name}-vmss"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.instance_count
  admin_username      = var.admin_username
  custom_data         = base64encode(local.provisioning_script_content)
  upgrade_mode        = "Automatic"
  health_probe_id     = var.is_frontend ? null : azurerm_lb_probe.backend[0].id
  tags                = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.vmss_identity.id]
  }

  # Enable termination notification to allow graceful shutdown
  termination_notification {
    enabled = true
    timeout = "PT5M" # 5 minutes
  }

  # Enable automatic repairs for unhealthy VMs
  dynamic "automatic_instance_repair" {
    for_each = var.is_frontend ? [] : [1]
    content {
      enabled      = true
      grace_period = "PT30M" # 30 minutes grace period
      action       = "Replace"
    }
  }

  # Configure scale-in policy to remove oldest VMs first
  scale_in {
    rule                   = "OldestVM"
    force_deletion_enabled = false
  }

  # Configure rolling upgrade policy for smoother updates
  rolling_upgrade_policy {
    max_batch_instance_percent              = 20
    max_unhealthy_instance_percent          = 20
    max_unhealthy_upgraded_instance_percent = 20
    pause_time_between_batches              = "PT1M"
    prioritize_unhealthy_instances_enabled  = true
  }

  # Prevent direct SSH access, use Bastion instead
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "${local.tier_name}-nic"
    primary = true

    ip_configuration {
      name                                         = "${local.tier_name}-ipconfig"
      primary                                      = true
      subnet_id                                    = var.subnet_id
      load_balancer_backend_address_pool_ids       = var.is_frontend ? null : [azurerm_lb_backend_address_pool.backend[0].id]
      application_gateway_backend_address_pool_ids = var.is_frontend ? [for pool in azurerm_application_gateway.frontend[0].backend_address_pool : pool.id] : null
    }
  }
}

# Auto-scaling settings - moved to a separate resource as required by provider version 4.27.0
resource "azurerm_monitor_autoscale_setting" "vmss_autoscale" {
  name                = "${var.resource_name_prefix}-${local.tier_name}-autoscale"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "AutoScale"

    capacity {
      default = var.instance_count
      minimum = 1
      maximum = 10
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }

  tags = var.tags
}
