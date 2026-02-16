module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Snapshot
  extend ActiveSupport::Concern

  included do
    supports :snapshots
    supports :snapshot_create do
      _("Cannot create snapshot of a template") if template?
    end
    supports :remove_snapshot do
      _("No snapshots available to remove") unless snapshots.count.positive?
    end
    supports :revert_to_snapshot do
      _("No snapshots available to revert to") unless snapshots.count.positive?
    end
    supports :remove_all_snapshots do
      _("No snapshots available to remove") unless snapshots.count.positive?
    end
  end

  def params_for_create_snapshot
    {
      :fields => [
        {
          :component  => 'text-field',
          :name       => 'name',
          :id         => 'name',
          :label      => _('Name'),
          :isRequired => true,
          :helperText => _('Must start with a letter and contain only letters, numbers, and underscores.'),
          :validate   => [
            {:type => 'required'},
            {:type => 'pattern', :pattern => '^[a-zA-Z][a-zA-Z0-9_]*$', :message => _('Must start with a letter and contain only letters, numbers, and underscores')}
          ]
        },
        {
          :component => 'textarea',
          :name      => 'description',
          :id        => 'description',
          :label     => _('Description')
        },
        {
          :component  => 'switch',
          :name       => 'memory',
          :id         => 'memory',
          :label      => _('Snapshot VM memory'),
          :onText     => _('Yes'),
          :offText    => _('No'),
          :isDisabled => current_state != 'on',
          :helperText => _('Snapshotting the memory is only available if the VM is powered on.')
        }
      ]
    }
  end

  def raw_create_snapshot(name, desc = nil, memory = false)
    $proxmox_log.info("Creating snapshot for VM #{self.name} with name=#{name.inspect}, desc=#{desc.inspect}, memory=#{memory.inspect}")
    raise MiqException::MiqVmSnapshotError, "Snapshot name is required" if name.blank?

    with_provider_connection do |connection|
      params = {:snapname => name}
      params[:description] = desc if desc.present?
      params[:vmstate] = 1 if memory && current_state == 'on'
      upid = connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/snapshot?#{URI.encode_www_form(params)}")
      wait_for_task(connection, upid)
    end
  rescue => err
    error_message = parse_api_error(err)
    create_notification(:vm_snapshot_failure, :error => error_message, :snapshot_op => "create")
    raise MiqException::MiqVmSnapshotError, error_message
  end

  def raw_remove_snapshot(snapshot_id)
    snapshot = snapshots.find_by(:id => snapshot_id)
    raise _("Requested VM snapshot not found, unable to remove snapshot") unless snapshot

    with_provider_connection do |connection|
      upid = connection.request(:delete, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/snapshot/#{snapshot.name}")
      wait_for_task(connection, upid)
    end
  rescue => err
    error_message = parse_api_error(err)
    create_notification(:vm_snapshot_failure, :error => error_message, :snapshot_op => "remove")
    raise MiqException::MiqVmSnapshotError, error_message
  end

  def raw_revert_to_snapshot(snapshot_id)
    raise MiqException::MiqVmError, unsupported_reason(:revert_to_snapshot) unless supports?(:revert_to_snapshot)

    snapshot = snapshots.find_by(:id => snapshot_id)
    raise _("Requested VM snapshot not found, unable to revert to snapshot") unless snapshot

    with_provider_connection do |connection|
      upid = connection.request(:post, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/snapshot/#{snapshot.name}/rollback")
      wait_for_task(connection, upid)
    end
  rescue => err
    error_message = parse_api_error(err)
    create_notification(:vm_snapshot_failure, :error => error_message, :snapshot_op => "revert")
    raise MiqException::MiqVmSnapshotError, error_message
  end

  def raw_remove_all_snapshots
    raise MiqException::MiqVmError, unsupported_reason(:remove_all_snapshots) unless supports?(:remove_all_snapshots)

    with_provider_connection do |connection|
      snapshot_list = connection.request(:get, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/snapshot")
      snapshot_list.each do |snapshot|
        next if snapshot["name"] == "current"

        upid = connection.request(:delete, "/nodes/#{host.ems_ref}/qemu/#{ems_ref}/snapshot/#{snapshot["name"]}")
        wait_for_task(connection, upid)
      end
    end
  rescue => err
    error_message = parse_api_error(err)
    create_notification(:vm_snapshot_failure, :error => error_message, :snapshot_op => "remove_all")
    raise MiqException::MiqVmSnapshotError, error_message
  end

  private

  def wait_for_task(connection, upid, timeout: 300, interval: 2)
    return unless upid.kind_of?(String) && upid.start_with?("UPID:")

    node = upid.split(":")[1]
    encoded_upid = URI.encode_www_form_component(upid)
    deadline = Time.now.utc + timeout

    loop do
      status = connection.request(:get, "/nodes/#{node}/tasks/#{encoded_upid}/status")
      case status["status"]
      when "stopped"
        return if status["exitstatus"] == "OK"

        raise "Task failed: #{status["exitstatus"]}"
      when "running"
        raise Timeout::Error, "Task #{upid} timed out after #{timeout}s" if Time.now.utc > deadline

        sleep(interval)
      else
        raise "Unknown task status: #{status["status"]}"
      end
    end
  end

  def parse_api_error(err)
    msg = err.to_s
    return msg unless msg.start_with?("ApiError:")

    json_str = msg.sub(/^ApiError:\s*/, "")
    data = JSON.parse(json_str)
    parts = []
    parts << data["message"].strip if data["message"].present?
    if data["errors"].kind_of?(Hash)
      data["errors"].each { |field, error| parts << "#{field}: #{error.strip}" }
    end
    parts.any? ? parts.join(" ") : msg
  rescue JSON::ParserError
    msg
  end
end
