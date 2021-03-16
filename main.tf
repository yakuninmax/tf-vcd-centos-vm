# Create VM
resource "vcd_vapp_vm" "vm" {
  vapp_name       = var.vapp
  name            = var.name
  catalog_name    = var.template.catalog
  template_name   = var.template.name
  memory          = var.ram * 1024
  cpus            = var.cpus
  cpu_cores       = var.cores_per_socket
  storage_profile = var.storage_profile
  computer_name   = var.name

  override_template_disk {
    size_in_mb  = var.system_disk_size * 1024
    bus_type    = var.system_disk_bus
    bus_number  = 0
    unit_number = 0
  }
  
  dynamic "network" {
    for_each = var.nics
      content {
        type               = "org"
        name               = network.value["network"]
        ip_allocation_mode = network.value["ip"] != "" ? "MANUAL" : "POOL"
        ip                 = network.value["ip"] != "" ? network.value["ip"] : null
      }
  }

  customization {
    enabled                    = true
    allow_local_admin_password = true
    auto_generate_password     = var.root_password != null ? false : true
    admin_password             = var.root_password != null ? var.root_password : null
  }
}

# Add VM data disks
resource "vcd_vm_internal_disk" "disk" {
  count = length(var.data_disks)
  
  vapp_name       = vcd_vapp_vm.vm.vapp_name
  vm_name         = vcd_vapp_vm.vm.name
  bus_type        = "paravirtual"
  size_in_mb      = var.data_disks[count.index].size * 1024
  bus_number      = 1
  unit_number     = count.index
  storage_profile = var.data_disks[count.index].storage_profile != "" ? var.data_disks[count.index].storage_profile : ""
}

# Insert media
resource "vcd_inserted_media" "media" {
  count      = var.media != null ? 1 : 0
  depends_on = [ vcd_vm_internal_disk.disk ]

  vapp_name   = vcd_vapp_vm.vm.vapp_name
  vm_name     = vcd_vapp_vm.vm.name
  catalog     = var.media.catalog
  name        = var.media.name
  eject_force = true
}

# Get random SSH port
resource "random_integer" "ssh-port" {
  count = var.allow_external_ssh == true ? 1 : 0
  
  min = 40000
  max = 49999
}

# SSH DNAT rule
resource "vcd_nsxv_dnat" "ssh-dnat-rule" {
  count = var.allow_external_ssh == true ? 1 : 0
  
  edge_gateway = data.vcd_edgegateway.edge.name
  network_type = "ext"
  network_name = tolist(data.vcd_edgegateway.edge.external_network)[0].name  

  original_address   = data.vcd_edgegateway.edge.external_network_ips[0]
  original_port      = var.external_ssh_port != "" ? var.external_ssh_port : random_integer.ssh-port[0].result
  translated_address = vcd_vapp_vm.vm.network[0].ip
  translated_port    = "22"
  protocol           = "tcp"

  description = "SSH to ${vcd_vapp_vm.vm.name}"
}

# SSH firewall rule
resource "vcd_nsxv_firewall_rule" "ssh-firewall-rule" {  
  count = var.allow_external_ssh == true ? 1 : 0

  edge_gateway = data.vcd_edgegateway.edge.name
  name         = "SSH to ${vcd_vapp_vm.vm.name}"

  source {
    ip_addresses = [trimspace(data.http.terraform-external-ip.body)]
  }

  destination {
    ip_addresses = [data.vcd_edgegateway.edge.external_network_ips[0]]
  }

  service {
    protocol = "tcp"
    port     = var.external_ssh_port != "" ? var.external_ssh_port : random_integer.ssh-port[0].result
  }
}

# Initial OS configuration
resource "null_resource" "initial-config" {

  provisioner "remote-exec" {
    
    connection {
      type        = "ssh"
      user        = "root"
      password    = vcd_vapp_vm.vm.customization[0].admin_password
      host        = var.allow_external_ssh == true ? var.external_ip != "" ? var.external_ip : data.vcd_edgegateway.edge.external_network_ips[0] : vcd_vapp_vm.vm.network[0].ip
      port        = var.allow_external_ssh == true ? var.external_ssh_port != "" ? var.external_ssh_port : random_integer.ssh-port[0].result : 22
      script_path = "/tmp/terraform_%RAND%.sh"
      timeout     = "15m"
    }

    inline = [
                "yum -y install cloud-utils-growpart",
                "growpart /dev/sda 2",
                "pvresize /dev/sda2",
                "lvextend -r -l +100%FREE /dev/cs/root",
                "yum -y update"
             ]
  }
}