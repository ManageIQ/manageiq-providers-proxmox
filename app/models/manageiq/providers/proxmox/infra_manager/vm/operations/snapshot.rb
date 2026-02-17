module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Snapshot
  extend ActiveSupport::Concern

  included do
    supports :snapshots
    supports(:snapshot_create) { _("Cannot create snapshot of a template") if template? }
    supports(:remove_snapshot) { _("No snapshots available") unless snapshots.any? }
    supports(:revert_to_snapshot) { _("No snapshots available") unless snapshots.any? }
    supports(:remove_all_snapshots) { _("No snapshots available") unless snapshots.any? }
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

  def raw_create_snapshot(name, desc = nil, memory = false) # rubocop:disable Style/OptionalBooleanParameter
    raise MiqException::MiqVmSnapshotError, "Snapshot name is required" if name.blank?

    $proxmox_log.info("Creating snapshot for VM #{self.name} with name=#{name.inspect}, desc=#{desc.inspect}, memory=#{memory.inspect}")
    with_snapshot_error_handling("create") do
      params = {:snapname => name}
      params[:description] = desc if desc.present?
      params[:vmstate] = 1 if memory && current_state == 'on'
      run_task(:post, "snapshot?#{URI.encode_www_form(params)}")
    end
  end

  def raw_remove_snapshot(snapshot_id)
    snapshot = find_snapshot!(snapshot_id)
    $proxmox_log.info("Removing snapshot #{snapshot.name.inspect} from VM #{name}")
    with_snapshot_error_handling("remove") { run_task(:delete, "snapshot/#{snapshot.name}") }
  end

  def raw_revert_to_snapshot(snapshot_id)
    snapshot = find_snapshot!(snapshot_id)
    $proxmox_log.info("Reverting VM #{name} to snapshot #{snapshot.name.inspect}")
    with_snapshot_error_handling("revert") { run_task(:post, "snapshot/#{snapshot.name}/rollback") }
  end

  def raw_remove_all_snapshots
    $proxmox_log.info("Removing all snapshots from VM #{name}")
    with_snapshot_error_handling("remove_all") do
      snapshots.reject { |s| s.name == "current" }.each { |s| run_task(:delete, "snapshot/#{s.name}") }
    end
  end

  private

  def vm_path
    "/nodes/#{host.ems_ref}/qemu/#{ems_ref}"
  end

  def run_task(method, path)
    with_provider_connection do |connection|
      upid = connection.request(method, "#{vm_path}/#{path}")
      wait_for_task(connection, upid)
    end
  end

  def find_snapshot!(snapshot_id)
    snapshots.find_by(:id => snapshot_id) || raise(_("Requested VM snapshot not found"))
  end

  def with_snapshot_error_handling(operation)
    yield
  rescue => err
    error_message = parse_api_error(err)
    create_notification(:vm_snapshot_failure, :error => error_message, :snapshot_op => operation)
    raise MiqException::MiqVmSnapshotError, error_message
  end

  def wait_for_task(connection, upid, timeout: 300, interval: 2)
    return unless upid.kind_of?(String) && upid.start_with?("UPID:")

    node = upid.split(":")[1]
    deadline = Time.now.utc + timeout

    loop do
      status = connection.request(:get, "/nodes/#{node}/tasks/#{upid}/status")
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

    data = JSON.parse(msg.sub(/^ApiError:\s*/, ""))
    parts = []
    parts << data["message"].strip if data["message"].present?
    data["errors"]&.each { |field, error| parts << "#{field}: #{error.strip}" }
    parts.any? ? parts.join(" ") : msg
  rescue JSON::ParserError
    msg
  end
end
