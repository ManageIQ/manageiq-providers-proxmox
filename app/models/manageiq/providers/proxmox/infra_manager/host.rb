# app/models/manageiq/providers/proxmox/infra_manager/host.rb

class ManageIQ::Providers::Proxmox::InfraManager::Host < ::Host
  supports :refresh_ems
  supports :quick_stats
  supports :smartstate_analysis

  VENDOR_TYPES = {
    "Proxmox" => "proxmox"  
  }.freeze

  def self.display_name(number = 1)
    n_('Host (Proxmox)', 'Hosts (Proxmox)', number)
  end

  def provider_object(connection = nil)
    connection ||= ext_management_system.connect
    connection
  end

  def verify_credentials(_auth_type = nil, _options = {})
    true
  end

  def get_node_status
    with_provider_connection do |connection|
      connection.get("/nodes/#{ems_ref}/status")
    end
  end

  def get_vms
    with_provider_connection do |connection|
      qemu_vms = connection.get("/nodes/#{ems_ref}/qemu")
      lxc_containers = connection.get("/nodes/#{ems_ref}/lxc")

      {
        :qemu => qemu_vms['data'] || [],
        :lxc  => lxc_containers['data'] || []
      }
    end
  end

  def get_storage_info
    with_provider_connection do |connection|
      connection.get("/nodes/#{ems_ref}/storage")
    end
  end

  def get_network_info
    with_provider_connection do |connection|
      connection.get("/nodes/#{ems_ref}/network")
    end
  end
end
