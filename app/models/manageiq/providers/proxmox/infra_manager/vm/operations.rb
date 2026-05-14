module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations
  extend ActiveSupport::Concern

  include Guest
  include Power
  include Snapshot

  included do
    supports :terminate do
      if !supports?(:control)
        unsupported_reason(:control)
      elsif power_state != "off"
        _("The VM is not powered off")
      end
    end
  end

  def raw_destroy
    with_provider_connection do |connection|
      connection.request(:delete, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}")
    end
  end
end
