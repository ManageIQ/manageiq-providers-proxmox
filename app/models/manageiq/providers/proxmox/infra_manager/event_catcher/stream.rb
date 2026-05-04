class ManageIQ::Providers::Proxmox::InfraManager::EventCatcher::Stream
  class ProviderUnreachable < ManageIQ::Providers::BaseManager::EventCatcher::Runner::TemporaryFailure
  end

  TASKS_LIMIT = 1000

  def initialize(ems, options = {})
    @ems = ems
    @stop_polling = false
    @poll_sleep = options[:poll_sleep] || 20.seconds
    @last_starttime_per_node = {}
    @active_tasks = {}
    @processed_upids = Set.new
    @initialized_at = Time.now.to_i
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

          poll_all_nodes(connection, &block)
          poll_active_tasks(connection, &block)
          sleep(@poll_sleep)
        end
      rescue => exception
        _log.error("Event polling error: #{exception.message}")
        raise ProviderUnreachable, exception.message
      end
    end
  end

  private

  def poll_all_nodes(connection, &block)
    node_names.each do |node_name|
      poll_node_tasks(connection, node_name, &block)
    end
  end

  def node_names
    @ems.hosts.pluck(:ems_ref)
  end

  def poll_node_tasks(connection, node_name, &block)
    start = 0
    max_starttime = @last_starttime_per_node[node_name]

    loop do
      params = build_task_query_params(node_name).merge(:start => start)
      tasks = connection.request(:get, "/nodes/#{node_name}/tasks", params) || []

      break if tasks.empty?

      tasks.each do |task|
        next unless vm_related_task?(task)

        task_starttime = task['starttime']
        max_starttime = task_starttime if max_starttime.nil? || task_starttime > max_starttime

        if task['endtime'].present?
          process_completed_task(task, &block)
        else
          track_active_task(task)
        end
      end

      break if tasks.size < TASKS_LIMIT

      start += TASKS_LIMIT
    end

    @last_starttime_per_node[node_name] = max_starttime if max_starttime
  end

  # Poll tracked active tasks individually to detect completion
  def poll_active_tasks(connection, &block)
    completed_upids = []

    @active_tasks.each do |upid, task_info|
      status = fetch_task_status(connection, task_info[:node], upid)
      next unless status && status['status'] == 'stopped'

      task_data = task_info[:task_data].merge(
        'endtime' => status['endtime'],
        'status'  => status['exitstatus']
      )

      process_completed_task(task_data, &block)
      completed_upids << upid
    end

    completed_upids.each { |upid| @active_tasks.delete(upid) }
  end

  def fetch_task_status(connection, node_name, upid)
    connection.request(:get, "/nodes/#{node_name}/tasks/#{upid}/status")
  rescue => e
    _log.warn("Failed to fetch task status for #{upid}: #{e.message}")
    nil
  end

  def build_task_query_params(node_name)
    params = {:limit => TASKS_LIMIT}
    last_starttime = @last_starttime_per_node[node_name]
    # Query tasks that started after our last seen starttime, or from initialization
    params[:since] = last_starttime ? last_starttime + 1 : @initialized_at
    params
  end

  def process_completed_task(task, &block)
    upid = task['upid']

    return if @processed_upids.include?(upid)
    return if task['endtime'] && task['endtime'] < @initialized_at
    return if task['endtime'].blank?

    block&.call(task)
    @processed_upids.add(upid)

    cleanup_processed_upids if @processed_upids.size > 10_000
  end

  def track_active_task(task)
    upid = task['upid']
    return if @active_tasks.key?(upid)

    @active_tasks[upid] = {
      :node      => task['node'],
      :starttime => task['starttime'],
      :task_data => task
    }
  end

  def cleanup_processed_upids
    @processed_upids.clear
  end

  def vm_related_task?(task)
    task['id'].present?
  end
end
