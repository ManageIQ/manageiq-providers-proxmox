class ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Collector
  def cluster
    @cluster ||= connection.request(:get, "/cluster/status")&.find { |item| item["type"] == "cluster" }
  end

  def cluster_status
    @cluster_status ||= connection.request(:get, "/cluster/status") || []
  end

  def nodes
    @nodes ||= cluster_resources_by_type["node"] || []
  end

  def node_details
    @node_details ||= nodes.each_with_object({}) do |node, hash|
      node_name = node["node"]
      hash[node_name] = {
        :status   => node_status(node_name),
        :version  => node_version(node_name),
        :storage  => node_storage(node_name),
        :ip       => node_ip(node_name),
        :networks => node_networks(node_name)
      }
    end
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

  def node_status(node_name)
    connection.request(:get, "/nodes/#{node_name}/status")
  rescue => e
    _log.warn("Failed to fetch status for node #{node_name}: #{e.message}")
    nil
  end

  def node_version(node_name)
    connection.request(:get, "/nodes/#{node_name}/version")
  rescue => e
    _log.warn("Failed to fetch version for node #{node_name}: #{e.message}")
    nil
  end

  def node_storage(node_name)
    connection.request(:get, "/nodes/#{node_name}/storage")
  rescue => e
    _log.warn("Failed to fetch storage for node #{node_name}: #{e.message}")
    []
  end

  def node_networks(node_name)
    connection.request(:get, "/nodes/#{node_name}/network")
  rescue => e
    _log.warn("Failed to fetch networks for node #{node_name}: #{e.message}")
    []
  end

  def node_ip(node_name)
    node_data = cluster_status.find { |item| item["type"] == "node" && item["name"] == node_name }
    node_data&.dig("ip")
  end
end
