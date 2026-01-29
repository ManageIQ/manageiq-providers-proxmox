class ManageIQ::Providers::Proxmox::Inventory::Collector::TargetCollection < ManageIQ::Providers::Proxmox::Inventory::Collector
  def initialize(_manager, target)
    super
    parse_targets!
  end

  def cluster
    @cluster ||= connection.request(:get, "/cluster/status")&.find { |item| item["type"] == "cluster" }
  end

  def nodes
    return [] if references(:hosts).blank?
    return @nodes if @nodes

    all_nodes = connection.request(:get, "/nodes")
    @nodes = all_nodes.select { |n| references(:hosts).include?(n["node"]) }
  end

  def vms
    return [] if references(:vms).blank?
    return @vms if @vms

    @vms = references(:vms).filter_map do |vm_ref|
      node, vmid = vm_ref.split("/")
      next unless node && vmid

      status_data = connection.request(:get, "/nodes/#{node}/qemu/#{vmid}/status/current")
      status_data&.merge("node" => node, "id" => "qemu/#{vmid}")
    end.compact
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
