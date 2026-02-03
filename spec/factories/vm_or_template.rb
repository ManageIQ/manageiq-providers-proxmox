FactoryBot.define do
  factory :vm_proxmox, :class => "ManageIQ::Providers::Proxmox::InfraManager::Vm", :parent => :vm_infra do
    vendor { "proxmox" }
  end
end
