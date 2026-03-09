class ManageIQ::Providers::Proxmox::Inventory::Collector::TargetCollection < ManageIQ::Providers::Proxmox::Inventory::Collector
  def initialize(_manager, target)
    super
    parse_targets!
  end

  def nodes
    return [] if references(:hosts).blank?
    return @nodes if @nodes

    all_nodes = connection.request(:get, "/nodes")
    @nodes = all_nodes.select { |n| references(:hosts).include?(n["node"]) }
  end

  def node_details
    @node_details ||= begin
      node_names = Set.new

      nodes.each { |n| node_names << n["node"] }
      vm_node_names.each { |name| node_names << name }

      node_names.index_with do |node_name|
        {
          :status   => node_status(node_name),
          :version  => node_version(node_name),
          :ip       => node_ip(node_name),
          :networks => node_networks(node_name)
        }
      end
    end
  end

  def storages
    @storages ||= begin
      all_storages = cluster_resources_by_type["storage"] || []
      target_node_names = node_details.keys
      all_storages.select { |s| target_node_names.include?(s["node"]) }
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

  def networks
    @networks ||= cluster_resources_by_type["network"]
  end

  private

  def vm_node_names
    return [] if references(:vms).blank?

    references(:vms).filter_map { |vm_ref| vm_ref.split("/").first }
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
