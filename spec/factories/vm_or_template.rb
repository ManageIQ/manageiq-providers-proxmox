FactoryBot.define do
  factory :vm_proxmox, :class => "ManageIQ::Providers::Proxmox::InfraManager::Vm", :parent => :vm_infra do
    vendor { "proxmox" }
  end

  factory :template_proxmox, :class => "ManageIQ::Providers::Proxmox::InfraManager::Template", :parent => :template_infra do
    vendor   { "proxmox" }
    location { "vmpvetest/900" }
  end
end
