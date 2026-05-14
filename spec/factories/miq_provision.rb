FactoryBot.define do
  factory :miq_provision_proxmox, :parent => :miq_provision, :class => "ManageIQ::Providers::Proxmox::InfraManager::Provision"
end
