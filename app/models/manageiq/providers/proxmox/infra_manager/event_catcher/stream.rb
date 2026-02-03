class ManageIQ::Providers::Proxmox::InfraManager::EventCatcher::Stream
  class ProviderUnreachable < ManageIQ::Providers::BaseManager::EventCatcher::Runner::TemporaryFailure
  end

  def initialize(ems, options = {})
    @ems = ems
    @stop_polling = false
    @poll_sleep = options[:poll_sleep] || 20.seconds
    @last_task_timestamps = {}
  end

  def start
    @stop_polling = false
  end

  def stop
    @stop_polling = true
  end

  def poll(&block)
    @ems.with_provider_connection do |connection|
      catch(:stop_polling) do
        loop do
          throw :stop_polling if @stop_polling

          poll_cluster_tasks(connection, &block)
          sleep @poll_sleep
        end
      rescue => exception
        _log.error("Event polling error: #{exception.message}")
        raise ProviderUnreachable, exception.message
      end
    end
  end

  private

  def poll_cluster_tasks(connection)
    tasks = connection.request(:get, "/cluster/tasks") || []

    tasks.each do |task|
      next if already_processed?(task)
      next unless vm_related_task?(task)

      event = task_to_event(task)
      next unless event

      yield(event)
      mark_processed(task)
    end
  end

  def vm_related_task?(task)
    task['id'].present?
  end

  def task_to_event(task)
    return nil if task['endtime'].blank?

    {
      :id        => task['upid'],
      :name      => task['type'],
      :timestamp => Time.at(task['endtime']).utc,
      :status    => task['status'],
      :vm_id     => task['id'],
      :node_id   => task['node'],
      :user      => task['user'],
      :type      => task['type'],
      :full_data => {
        :upid      => task['upid'],
        :node_id   => task['node'],
        :status    => task['status'],
        :user      => task['user'],
        :id        => task['id'],
        :type      => task['type'],
        :starttime => task['starttime'],
        :endtime   => task['endtime'],
      }
    }
  end

  def already_processed?(task)
    @last_task_timestamps[task['upid']].present?
  end

  def mark_processed(task)
    @last_task_timestamps[task['upid']] = task['endtime']
  end
end
