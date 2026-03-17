module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Guest
  extend ActiveSupport::Concern

  included do
    supports :reboot_guest do
      if current_state != "on"
        _("The VM is not powered on")
      elsif !qemu_agent_running?
        _("The QEMU guest agent is not running")
      else
        unsupported_reason(:control)
      end
    end

    supports :shutdown_guest do
      if current_state != "on"
        _("The VM is not powered on")
      elsif !qemu_agent_running?
        _("The QEMU guest agent is not running")
      else
        unsupported_reason(:control)
      end
    end

    supports :reset do
      if current_state != "on"
        _("The VM is not powered on")
      else
        unsupported_reason(:control)
      end
    end
  end

  def raw_shutdown_guest
    with_provider_connection do |connection|
      connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/status/shutdown")
    end
  end

  def raw_reboot_guest
    with_provider_connection do |connection|
      connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/status/reboot")
    end
  end

  def raw_reset
    with_provider_connection do |connection|
      connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/status/reset")
    end
  end

  private

  def qemu_agent_running?
    tools_status == "toolsOk"
  end
end
