FactoryBot.define do
  factory :ems_proxmox, :class => "ManageIQ::Providers::Proxmox::InfraManager", :parent => :ems_infra

  factory :ems_proxmox_with_authentication, :parent => :ems_proxmox do
    authtype { "default" }
  end

  factory :ems_proxmox_with_vcr_authentication, :parent => :ems_proxmox do
    hostname { VcrSecrets.proxmox.hostname }
    port { VcrSecrets.proxmox.port }
    security_protocol { VcrSecrets.proxmox.security_policy }
    after(:create) do |ems|
      ems.authentications << FactoryBot.create(:authentication, :userid => VcrSecrets.proxmox.username, :password => VcrSecrets.proxmox.password)
    end
  end
end
