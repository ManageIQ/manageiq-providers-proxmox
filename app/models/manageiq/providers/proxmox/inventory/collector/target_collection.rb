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
    return @vms if defined?(@vms)

    @vms = if references(:vms).present?
             references(:vms).filter_map do |vm_ref|
               if vm_ref.include?("/")
                 node, vmid = vm_ref.split("/")
                 next unless node && vmid

                 collect_vm_details("node" => node, "vmid" => vmid, "id" => "qemu/#{vmid}")
               else
                 find_vm_by_vmid(vm_ref)
               end
             end
           elsif references(:hosts).present?
             # Host-targeted refresh: collect all VMs on the targeted nodes
             (cluster_resources_by_type["qemu"] || [])
               .select { |vm| references(:hosts).include?(vm["node"]) }
               .map { |vm| collect_vm_details(vm) }
           else
             []
           end
  end

  def find_vm_by_vmid(vmid)
    vm = (cluster_resources_by_type["qemu"] || []).find { |v| v["vmid"].to_s == vmid.to_s }
    return unless vm

    collect_vm_details("node" => vm["node"], "vmid" => vmid, "id" => "qemu/#{vmid}")
  end

  def networks
    @networks ||= cluster_resources_by_type["network"]
  end

  private

  def vm_node_names
    vms.filter_map { |vm| vm["node"] }
  end

  def parse_targets!
    snapshot = target.targets.dup
    snapshot.each do |t|
      case t
      when InventoryRefresh::Target
        case t.association
        when :vms_and_templates, :vms
          add_target!(:vms, t.manager_ref[:ems_ref])
        end
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
