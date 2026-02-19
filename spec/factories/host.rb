FactoryBot.define do
  factory :host_proxmox, :class => "ManageIQ::Providers::Proxmox::InfraManager::Host", :parent => :host
end
