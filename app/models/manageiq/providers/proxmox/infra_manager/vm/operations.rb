module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations
  extend ActiveSupport::Concern
  include Snapshot
  include Configuration

  included do
    supports(:terminate) { unsupported_reason(:control) }
  end
end

