module ManageIQ::Providers::Proxmox::InfraManager::Provision::Cloning
  def prepare_for_clone_task
    $proxmox_log.info("Provision options: #{options.inspect}")

    linked_clone = get_option(:linked_clone)
    clone_opts = {
      :name        => dest_name,
      :description => get_option(:vm_description),
      :full_clone  => !linked_clone
    }

    if clone_opts[:full_clone]
      storage_id = get_option(:placement_ds_name)
      if storage_id.present?
        storage = Storage.find_by(:id => storage_id)
        clone_opts[:storage] = storage&.name
      end
      clone_opts[:format] = get_option(:disk_format)
    end

    clone_opts
  end

  def start_clone(clone_opts)
    $proxmox_log.info("Clone options: #{clone_opts.inspect}")

    with_provider_connection do |connection|
      node_id, template_vmid = source.location.split('/')
      template_vmid ||= source.ems_ref

      new_vmid = connection.request(:get, "/cluster/nextid")
      $proxmox_log.info("Cloning from #{node_id}/#{template_vmid} to new VMID #{new_vmid}")

      params = build_clone_params(new_vmid, clone_opts)
      $proxmox_log.info("API params: #{params.inspect}")

      task_upid = connection.request(:post, "/nodes/#{node_id}/qemu/#{template_vmid}/clone?#{URI.encode_www_form(params)}")
      $proxmox_log.info("Clone task UPID: #{task_upid}")

      phase_context[:clone_task_upid] = task_upid
      phase_context[:new_vmid] = new_vmid
      phase_context[:clone_node_id] = node_id
    end
  end

  private

  def build_clone_params(new_vmid, clone_opts)
    params = {:newid => new_vmid.to_i, :name => clone_opts[:name]}
    params[:description] = clone_opts[:description] if clone_opts[:description].present?

    if clone_opts[:full_clone]
      params[:full] = 1
      params[:storage] = clone_opts[:storage] if clone_opts[:storage].present?
      params[:format] = clone_opts[:format] if clone_opts[:format].present?
    end

    params
  end
end
