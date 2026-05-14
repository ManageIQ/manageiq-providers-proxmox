class ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Collector
  def nodes
    @nodes ||= cluster_resources_by_type["node"] || []
  end

  def node_details
    @node_details ||= nodes.each_with_object({}) do |node, hash|
      node_name = node["node"]
      hash[node_name] = {
        :status   => node_status(node_name),
        :version  => node_version(node_name),
        :ip       => node_ip(node_name),
        :networks => node_networks(node_name)
      }
    end
  end

  def vms
    @vms ||= cluster_resources_by_type["qemu"]&.map { |vm| collect_vm_details(vm) } || []
  end

  def storages
    @storages ||= cluster_resources_by_type["storage"] || []
  end

  def networks
    @networks ||= cluster_resources_by_type["network"]
  end
end
