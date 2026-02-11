class ManageIQ::Providers::Proxmox::Inventory::Collector::TargetCollection < ManageIQ::Providers::Proxmox::Inventory::Collector
  def initialize(_manager, target)
    super
    parse_targets!
  end

  def cluster
    @cluster ||= cluster_status&.find { |item| item["type"] == "cluster" }
  end

  def cluster_status
    @cluster_status ||= connection.request(:get, "/cluster/status") || []
  end

  def nodes
    return [] if references(:hosts).blank?
    return @nodes if @nodes

    all_nodes = connection.request(:get, "/nodes")
    @nodes = all_nodes.select { |n| references(:hosts).include?(n["node"]) }
  end

  def node_details
    @node_details ||= nodes.each_with_object({}) do |node, hash|
      node_name = node["node"]
      hash[node_name] = {
        :status  => node_status(node_name),
        :version => node_version(node_name),
        :storage => node_storage(node_name),
        :ip      => node_ip(node_name)
      }
    end
  end

  def vms
    return [] if references(:vms).blank?
    return @vms if @vms

    @vms = references(:vms).filter_map do |vm_ref|
      node, vmid = vm_ref.split("/")
      next unless node && vmid

      collect_vm_details("node" => node, "vmid" => vmid, "id" => "qemu/#{vmid}")
    end
  end

  def storages
    []
  end

  def networks
    []
  end

  private

  def connection
    @connection ||= manager.connect
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

  def node_ip(node_name)
    node_data = cluster_status.find { |item| item["type"] == "node" && item["name"] == node_name }
    node_data&.dig("ip")
  end

  def parse_targets!
    target.targets.each do |t|
      case t
      when Vm
        add_target!(:vms, t.location)
      when Host
        add_target!(:hosts, t.ems_ref)
      when EmsCluster
        add_target!(:ems_clusters, t.ems_ref)
      end
    end
  end
end
