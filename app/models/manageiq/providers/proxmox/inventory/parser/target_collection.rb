class ManageIQ::Providers::Proxmox::Inventory::Parser::TargetCollection < ManageIQ::Providers::Proxmox::Inventory::Parser::InfraManager
  def storages
    parsed_storages = {}
    parsed_host_storages = Set.new
    target_node_names = collector.node_details.keys

    collector.storages.each do |storage|
      next unless storage["status"] == "available"

      storage_name = storage["storage"]
      node_name = storage["node"]
      shared = storage["shared"] == 1
      ems_ref = shared ? storage_name : "#{node_name}/#{storage_name}"

      # Only process storages for targeted nodes
      next unless target_node_names.include?(node_name)

      unless parsed_storages[ems_ref]
        total_space = storage["maxdisk"]
        used_space = storage["disk"]
        free_space = total_space && used_space ? total_space - used_space : nil

        parsed_storages[ems_ref] = persister.storages.build(
          :ems_ref            => ems_ref,
          :name               => shared ? storage_name : "#{storage_name} (#{node_name})",
          :store_type         => storage["plugintype"],
          :total_space        => total_space,
          :free_space         => free_space,
          :multiplehostaccess => shared,
          :location           => storage_name
        )
      end

      # Prevent duplicate host_storage entries for the same host/storage combination
      host_storage_key = "#{node_name}/#{ems_ref}"
      next if parsed_host_storages.include?(host_storage_key)

      parsed_host_storages.add(host_storage_key)
      persister.host_storages.build(
        :storage => persister.storages.lazy_find(ems_ref),
        :host    => persister.hosts.lazy_find(node_name)
      )
    end
  end
end
