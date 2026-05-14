module ManageIQ::Providers::Proxmox::InfraManager::Provision::Cloning
  def find_destination_in_vmdb(ems_ref)
    source.ext_management_system.vms.find_by(:ems_ref => ems_ref)
  end

  def prepare_for_clone_task
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
        clone_opts[:storage] = storage&.location
      end
      clone_opts[:format] = get_option(:disk_format)
    end

    clone_opts
  end

  def start_clone(clone_opts)
    with_provider_connection do |connection|
      src_node_id, template_vmid = source.location.split('/')
      template_vmid ||= source.ems_ref

      dest_node_id = destination_node_id || src_node_id

      new_vmid = connection.request(:get, "/cluster/nextid")
      params = build_clone_params(new_vmid, clone_opts, dest_node_id, src_node_id)

      task_upid = connection.request(:post, "/nodes/#{src_node_id}/qemu/#{template_vmid}/clone?#{URI.encode_www_form(params)}")

      phase_context[:clone_task_upid] = task_upid
      phase_context[:new_vmid]        = new_vmid
      phase_context[:clone_node_id]   = dest_node_id
    end
  end

  # Starts hardware customization (config PUT)
  def start_hardware_customization
    node_id  = phase_context[:clone_node_id]
    new_vmid = phase_context[:new_vmid]
    $proxmox_log.info("customize_cloned_vm options: #{options.inspect}")

    with_provider_connection do |connection|
      apply_hardware_customization(connection, node_id, new_vmid)
    end
  end

  def start_resize_boot_disk
    node_id  = phase_context[:clone_node_id]
    new_vmid = phase_context[:new_vmid]

    with_provider_connection do |connection|
      resize_boot_disk(connection, node_id, new_vmid)
    end
  end

  def start_tpm_rekey
    return unless get_option(:renew_tpm)

    node_id  = phase_context[:clone_node_id]
    new_vmid = phase_context[:new_vmid]

    with_provider_connection do |connection|
      handle_tpm_rekey(connection, node_id, new_vmid)
    end
  end

  def customize_task_complete?
    upid   = phase_context[:customize_task_upid]
    return true if upid.nil?

    node_id = phase_context[:clone_node_id]
    with_provider_connection do |connection|
      status = connection.request(:get, "/nodes/#{node_id}/tasks/#{URI.encode_uri_component(upid)}/status")
      $proxmox_log.info("Customize task #{upid}: #{status['status']} (exit: #{status['exitstatus']})")

      case status["status"]
      when "stopped"
        raise MiqException::MiqProvisionError, "Task failed: #{status['exitstatus']}" unless status["exitstatus"] == "OK"

        phase_context[:customize_task_upid] = nil
        true
      else
        false
      end
    end
  end

  private

  # Builds and PUTs the VM config. Returns the UPID when Proxmox returns one
  def apply_hardware_customization(connection, node_id, new_vmid)
    sockets = get_option(:number_of_sockets).to_i
    cores   = get_option(:cores_per_socket).to_i
    memory  = get_option(:vm_memory).to_i
    bridge  = get_option(:vlan)

    # Seed params from extra_config first; explicit dialog fields override on conflict.
    params = parse_extra_config

    params[:sockets] = sockets if sockets > 0
    params[:cores]   = cores   if cores   > 0
    params[:memory]  = memory  if memory  > 0

    if bridge.present?
      config    = connection.request(:get, "/nodes/#{node_id}/qemu/#{new_vmid}/config")
      net0      = config["net0"].to_s
      nic_model = net0.split(",").first.split("=").first.presence || "virtio"
      params[:net0] = "#{nic_model},bridge=#{bridge}"
    end

    return if params.empty?

    $proxmox_log.info("Applying hardware customization to VM #{new_vmid}: #{params}")
    upid = connection.request(:put, "/nodes/#{node_id}/qemu/#{new_vmid}/config?#{URI.encode_www_form(params)}")
    upid if upid.kind_of?(String) && upid.start_with?("UPID:")
  end

  def handle_tpm_rekey(connection, node_id, new_vmid)
    config    = connection.request(:get, "/nodes/#{node_id}/qemu/#{new_vmid}/config")
    tpm_value = config["tpmstate0"]
    return unless tpm_value

    version        = tpm_value[/version=(v\d+\.\d+)/, 1] || "v2.0"
    target_storage = clone_target_storage || tpm_value.split(":").first

    $proxmox_log.info("Re-keying TPM for VM #{new_vmid}: removing cloned state, provisioning fresh on #{target_storage} (#{version})")

    connection.request(:put, "/nodes/#{node_id}/qemu/#{new_vmid}/unlink?#{URI.encode_www_form(:idlist => 'tpmstate0', :force => 1)}")

    upid = connection.request(:put, "/nodes/#{node_id}/qemu/#{new_vmid}/config?#{URI.encode_www_form(:tpmstate0 => "#{target_storage}:0,version=#{version}")}")
    upid if upid.kind_of?(String) && upid.start_with?("UPID:")
  end

  def resize_boot_disk(connection, node_id, new_vmid)
    requested_gb = get_option(:allocated_disk_storage).to_i
    return if requested_gb <= 0

    config = connection.request(:get, "/nodes/#{node_id}/qemu/#{new_vmid}/config")
    disk_slot = config.keys.grep(/^(scsi|ide|sata|virtio|nvme)\d+$/).find do |key|
      config[key].to_s.exclude?("media=cdrom") && config[key].to_s.exclude?("tpmstate")
    end
    return unless disk_slot

    disk_str   = config[disk_slot].to_s
    current_gb = parse_disk_size_gb(disk_str)

    if requested_gb > current_gb
      increase_gb = requested_gb - current_gb
      $proxmox_log.info("Resizing boot disk #{disk_slot} of VM #{new_vmid}: +#{increase_gb}G (#{current_gb}G -> #{requested_gb}G)")
      upid = connection.request(:put, "/nodes/#{node_id}/qemu/#{new_vmid}/resize?#{URI.encode_www_form(:disk => disk_slot, :size => "+#{increase_gb}G")}")
      upid if upid.kind_of?(String) && upid.start_with?("UPID:")
    elsif requested_gb < current_gb
      $proxmox_log.warn("Requested disk size #{requested_gb}G is smaller than current #{current_gb}G for VM #{new_vmid} — skipping resize (Proxmox does not support shrinking)")
    end
  end

  def parse_disk_size_gb(disk_str)
    size_part = disk_str.split(",").filter_map { |p| p[/size=(\d+(?:\.\d+)?[TGMK]?)/i, 1] }.first
    return 0 unless size_part

    value = size_part.to_f
    case size_part[-1].upcase
    when "T" then (value * 1024).to_i
    when "M" then (value / 1024).ceil
    when "K" then (value / 1024 / 1024).ceil
    else value.to_i
    end
  end

  def clone_target_storage
    storage_id = get_option(:placement_ds_name)
    return nil if storage_id.blank?

    Storage.find_by(:id => storage_id)&.location
  end

  def destination_node_id
    host_id = get_option(:placement_host_name)
    return nil if host_id.blank?

    host = Host.find_by(:id => host_id)
    host&.ems_ref
  end

  # Parses the :extra_config option, which returns a symbol-keyed hash ready to be merged into the config params.
  def parse_extra_config
    raw = get_option(:extra_config).to_s.strip
    return {} if raw.blank?

    parsed = JSON.parse(raw)
    unless parsed.kind_of?(Hash)
      $proxmox_log.warn("extra_config is not a JSON object — ignoring: #{raw.inspect}")
      return {}
    end

    parsed.transform_keys(&:to_sym)
  rescue JSON::ParserError => e
    $proxmox_log.warn("extra_config contains invalid JSON — ignoring: #{e.message}")
    {}
  end

  def build_clone_params(new_vmid, clone_opts, dest_node_id = nil, src_node_id = nil)
    params = {:newid => new_vmid.to_i, :name => clone_opts[:name]}
    params[:description] = clone_opts[:description] if clone_opts[:description].present?
    params[:target] = dest_node_id if dest_node_id.present? && dest_node_id != src_node_id

    if clone_opts[:full_clone]
      params[:full] = 1
      params[:storage] = clone_opts[:storage] if clone_opts[:storage].present?
      params[:format] = clone_opts[:format] if clone_opts[:format].present?
    end

    params
  end
end
