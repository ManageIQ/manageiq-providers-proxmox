module ManageIQ::Providers::Proxmox::InfraManager::Vm::Reconfigure
  extend ActiveSupport::Concern

  DISK_SLOT_PATTERN  = /^(scsi|ide|sata|virtio|nvme)\d+$/
  NIC_SLOT_PATTERN   = /^net\d+$/
  MAC_PATTERN        = /[0-9a-fA-F:]{17}/
  TASK_TIMEOUT       = 300
  TASK_POLL_INTERVAL = 2

  included do
    supports :reconfigure do
      _("Cannot reconfigure a template") if template?
      _("The VM is not connected to a provider") unless ext_management_system
    end
    supports :reconfigure_disks
    supports :reconfigure_network_adapters
    supports :reconfigure_disksize
  end

  def reconfigurable?
    !template? && ext_management_system
  end

  def max_total_vcpus = 128
  def max_cpu_cores_per_socket(_total_vcpus = nil) = 128
  def max_vcpus                = host&.hardware&.cpu_sockets || 1
  def max_memory_mb            = 4.terabytes / 1.megabyte
  def scsi_controller_types    = %w[scsi virtio sata ide]
  def scsi_controller_default_type = 'scsi'

  def build_config_spec(options)
    cores   = options[:cores_per_socket]&.to_i
    cpus    = options[:number_of_cpus]&.to_i
    sockets = options[:number_of_sockets]&.to_i
    memory  = (options[:vm_memory] || options[:memory])&.to_i

    validate_hotplug(cpus, memory) if power_state == "on"

    {
      :cores        => cores,
      :sockets      => (sockets&.nonzero? || (cpus / (cores || cpu_cores_per_socket || 1)) if cpus),
      :memory       => memory,
      :_disk_ops    => compact_ops(options, :disk_add, :disk_resize, :disk_remove),
      :_network_ops => compact_ops(options, :network_adapter_add, :network_adapter_edit, :network_adapter_remove)
    }.compact
  end

  def raw_reconfigure(spec)
    with_provider_connection do |connection|
      process_disk_ops(connection, spec.delete(:_disk_ops))
      process_network_ops(connection, spec.delete(:_network_ops))
      apply_config(connection, spec) unless spec.empty?
    end
  end

  private

  def validate_hotplug(cpus, memory)
    if cpus
      raise MiqException::MiqVmError, _("Cannot reduce CPUs on running VM") if cpus < cpu_total_cores
      raise MiqException::MiqVmError, _("CPU hotplug not enabled") if cpus > cpu_total_cores && !cpu_hot_add_enabled
    end

    return unless memory

    raise MiqException::MiqVmError, _("Cannot reduce memory on running VM") if memory < ram_size
    raise MiqException::MiqVmError, _("Memory hotplug requires hotplug=memory and NUMA") if memory > ram_size && !memory_hot_add_enabled
  end

  def compact_ops(options, *keys)
    ops = keys.each_with_object({}) { |k, h| h[k.to_s.split('_').last.to_sym] = options[k] }
    ops.compact!
    ops.presence
  end

  # Disk Operations

  def process_disk_ops(connection, ops)
    return unless ops

    config = fetch_config(connection)
    ops[:add]&.each    { |s| add_disk(connection, config, s) }
    ops[:resize]&.each { |s| resize_disk(connection, s) }
    ops[:remove]&.each { |s| remove_disk(connection, s) }
  end

  def add_disk(connection, config, spec)
    controller = spec['controller_type'] || spec['new_controller_type'] || scsi_controller_default_type
    slot = next_slot(config, controller)
    storage = spec['datastore'] || storages.first&.location || 'local-lvm'
    size_gb = spec['disk_size_in_mb'].to_i / 1024

    execute_reconfigure_task(connection, :put, "config?#{slot}=#{build_disk_value(storage, size_gb, spec)}")
  end

  def build_disk_value(storage, size_gb, spec)
    spec = {'ssd_emulation' => true, 'discard' => true, 'iothread' => true}.merge(spec)

    [
      "#{storage}:#{size_gb}",
      ("ssd=1" if spec['ssd_emulation']),
      ("discard=on" if spec['discard']),
      ("iothread=1" if spec['iothread']),
      ("cache=#{spec['cache']}" if spec['cache'].present?),
      ("backup=0" if spec['backup'] == false),
      ("replicate=0" if spec['replicate'] == false)
    ].compact.join(",")
  end

  def resize_disk(connection, spec)
    slot = find_disk_slot(spec)
    return unless slot

    new_mb = spec['disk_size_in_mb'].to_i
    current_mb = disks.find { |d| d.location == slot }&.size.to_i / 1.megabyte
    return if new_mb <= current_mb

    increase_gb = ((new_mb - current_mb) / 1024.0).ceil
    execute_reconfigure_task(connection, :put, "resize?disk=#{slot}&size=%2B#{increase_gb}G")
  end

  def remove_disk(connection, spec)
    slot = find_disk_slot(spec)
    execute_reconfigure_task(connection, :put, "config?delete=#{slot}") if slot
  end

  def find_disk_slot(spec)
    name = spec['disk_name']
    return name if name&.match?(DISK_SLOT_PATTERN)
    return disks.find { |d| d.filename == name }&.location if name
    return unless spec['id']&.start_with?('disk')

    disks.find_by(:id => spec['id'].delete_prefix('disk').to_i)&.location
  end

  # Network Operations

  def process_network_ops(connection, ops)
    return unless ops

    config = fetch_config(connection)
    ops[:add]&.each    { |s| add_nic(connection, config, s) }
    ops[:edit]&.each   { |s| edit_nic(connection, config, s) }
    ops[:remove]&.each { |s| remove_nic(connection, config, s) }
  end

  def add_nic(connection, config, spec)
    execute_reconfigure_task(connection, :put, "config?#{next_slot(config, 'net')}=#{encode_nic(spec)}")
  end

  def edit_nic(connection, config, spec)
    slot = find_nic_slot(spec, config)
    return unless slot

    current = parse_nic_config(config[slot])
    merged = {
      :model  => spec['network_adapter_type'] || current[:model],
      :bridge => spec['network'] || spec['cloud_network'] || current[:bridge],
      :mac    => spec['mac_address'] || current[:mac]
    }
    execute_reconfigure_task(connection, :put, "config?#{slot}=#{encode_nic(merged)}")
  end

  def remove_nic(connection, config, spec)
    slot = find_nic_slot(spec, config)
    execute_reconfigure_task(connection, :put, "config?delete=#{slot}") if slot
  end

  def find_nic_slot(spec, _config)
    return spec['nic_id'] if spec['nic_id']&.match?(NIC_SLOT_PATTERN)

    name = spec['name'] || spec.dig('network', 'name')
    slot = name&.split&.first
    return slot if slot&.match?(NIC_SLOT_PATTERN)

    return unless spec['id']&.start_with?('network')

    nic = hardware&.nics&.find_by(:id => spec['id'].delete_prefix('network').to_i)
    nic&.location
  end

  def parse_nic_config(str)
    str = str.to_s
    first_part = str.split(',').first || ''
    {
      :model  => first_part.split('=').first || 'virtio',
      :bridge => str[/bridge=([^,]+)/, 1] || 'vmbr0',
      :mac    => str[MAC_PATTERN]
    }
  end

  def encode_nic(spec)
    model  = spec['network_adapter_type'] || spec[:model] || 'virtio'
    bridge = spec['network'] || spec['cloud_network'] || spec[:bridge] || 'vmbr0'
    mac    = spec['mac_address'] || spec[:mac]

    value = mac.present? ? "#{model}=#{mac},bridge=#{bridge}" : "#{model},bridge=#{bridge}"
    URI.encode_www_form_component(value)
  end

  # Proxmox API

  def fetch_config(connection)
    connection.request(:get, "#{vm_path}/config")
  end

  def apply_config(connection, spec)
    params = spec.map { |k, v| "#{k}=#{v}" }.join("&")
    execute_reconfigure_task(connection, :put, "config?#{params}")
  end

  def execute_reconfigure_task(connection, method, path)
    upid = connection.request(method, "#{vm_path}/#{path}")
    await_reconfigure_task(connection, upid)
  end

  def await_reconfigure_task(connection, upid)
    return unless upid.kind_of?(String) && upid.start_with?("UPID:")

    node = upid.split(":")[1]
    deadline = Time.now.utc + TASK_TIMEOUT

    loop do
      status = connection.request(:get, "/nodes/#{node}/tasks/#{upid}/status")
      case status["status"]
      when "stopped"
        raise MiqException::MiqVmError, "Task failed: #{status["exitstatus"]}" unless status["exitstatus"] == "OK"

        return
      when "running"
        raise MiqException::MiqVmError, "Task timed out" if Time.now.utc > deadline

        sleep(TASK_POLL_INTERVAL)
      else
        raise MiqException::MiqVmError, "Unknown task status: #{status["status"]}"
      end
    end
  end

  def next_slot(config, prefix)
    existing = config.keys.grep(/^#{prefix}\d+$/)
    max = existing.map { |k| k[/\d+/].to_i }.max || -1
    "#{prefix}#{max + 1}"
  end
end
