class ManageIQ::Providers::Proxmox::Inventory::Parser::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Parser
  def parse
    clusters
    hosts
    storages
    networks
    vms
  end

  def clusters
  end

  def hosts
    collector.nodes.each do |host|
      ems_ref = host["id"].gsub("node/", "")
      persister.hosts.build(
        :ems_ref     => ems_ref,
        :uid_ems     => ems_ref,
        :name        => host["node"],
        :vmm_vendor  => "proxmox",
        :vmm_product => "Proxmox VE",
        :power_state => host["status"] == "online" ? "on" : "off"
      )
    end
  end

  def storages
    collector.storages.each do |storage|
      ems_ref = storage["id"].gsub("storage/", "")

      storage_obj = persister.storages.build(
        :ems_ref => ems_ref,
        :name    => storage["storage"]
      )

      persister.host_storages.build(
        :storage => storage_obj,
        :host    => persister.hosts.lazy_find(storage["node"])
      )
    end
  end

  def networks
    collector.networks.each do |network|
    end
  end

  def vms
    collector.vms.each do |vm|
      ems_ref  = vm["id"].gsub("qemu/", "")
      host     = persister.hosts.lazy_find(vm["node"]) if vm["node"]
      template = vm["template"] == 1
      raw_power_state = template ? "never" : vm["status"]

      vm_obj = persister.vms_and_templates.build(
        :type            => "#{persister.manager.class}::#{template ? "Template" : "Vm"}",
        :ems_ref         => ems_ref,
        :uid_ems         => ems_ref,
        :name            => vm["name"],
        :template        => template,
        :raw_power_state => raw_power_state,
        :host            => host,
        :location        => "#{vm["node"]}/#{vm["vmid"]}",
        :vendor          => "proxmox"
      )
    end
  end
end
