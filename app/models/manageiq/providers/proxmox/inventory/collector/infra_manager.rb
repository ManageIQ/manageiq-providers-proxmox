class ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Collector
  def cluster
    @cluster ||= connection.request(:get, "/cluster/status")&.find { |item| item["type"] == "cluster" }
  end

  def nodes
    @nodes ||= cluster_resources_by_type["node"] || []
  end

  def vms
    @vms ||= cluster_resources_by_type["qemu"]&.map { |vm| collect_vm_details(vm) } || []
  end

  def storages
    @storages ||= cluster_resources_by_type["storage"]
  end

  def networks
    @networks ||= cluster_resources_by_type["network"]
  end

  private

  def connection
    @connection ||= manager.connect
  end

  def cluster_resources_by_type
    @cluster_resources_by_type = cluster_resources.group_by { |res| res["type"] }
  end

  def cluster_resources
    connection.request(:get, "/cluster/resources")
  end
end
