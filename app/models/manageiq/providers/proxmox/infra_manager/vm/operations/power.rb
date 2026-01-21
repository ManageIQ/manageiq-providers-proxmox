module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Power
  extend ActiveSupport::Concern

  def raw_start
    with_provider_connection do |connection|
      connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/status/start")
    end
  end

  def raw_stop
    with_provider_connection do |connection|
      connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/status/stop")
    end
  end
end
