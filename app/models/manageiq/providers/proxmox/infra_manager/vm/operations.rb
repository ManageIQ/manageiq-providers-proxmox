module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations
  extend ActiveSupport::Concern

  include Power
  include Snapshot
end
