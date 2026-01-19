class ManageIQ::Providers::Proxmox::InfraManager::MetricsCollectorWorker::Runner < ManageIQ::Providers::BaseManager::MetricsCollectorWorker::Runner
  def before_exit(_message, _exit_code)
    @collector = nil
  end

  def do_before_work_loop
    @ems = ManageIQ::Providers::Proxmox::InfraManager.find(@cfg[:ems_id])
    @collector = ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager.new(@ems, nil)
  end

  def do_work
    _log.info("Collecting metrics for EMS [#{@ems.name}]...")
    
    cluster_metrics = @collector.cluster_metrics
    _log.info("Cluster metrics: CPU=#{cluster_metrics[:cpu_usage_rate_average].round(2)}%, Memory=#{cluster_metrics[:mem_usage_rate_average].round(2)}%")
    
    @ems.hosts.each do |host|
      host_metrics = @collector.host_metrics_data(host.ems_ref)
      next if host_metrics.empty?
      
      _log.info("Host [#{host.name}]: CPU=#{host_metrics[:cpu_usage_rate_average].round(2)}%, Memory=#{host_metrics[:mem_usage_rate_average].round(2)}%")
      
      perf_capture_realtime(host, host_metrics)
    end
    
    @ems.vms.each do |vm|
      vm_metrics = @collector.vm_metrics_data(vm.ems_ref)
      next if vm_metrics.empty?
      
      _log.info("VM [#{vm.name}]: CPU=#{vm_metrics[:cpu_usage_rate_average].round(2)}%, Memory=#{vm_metrics[:mem_usage_rate_average].round(2)}%")
      
      perf_capture_realtime(vm, vm_metrics)
    end
  rescue => err
    _log.error("Error collecting metrics: #{err}")
    _log.log_backtrace(err)
  end

  private

  def perf_capture_realtime(target, metrics)
    timestamp = Time.now.utc
    
    metric_data = {
      :timestamp                      => timestamp,
      :capture_interval               => 20,
      :resource_type                  => target.class.name,
      :resource_id                    => target.id,
      :cpu_usage_rate_average         => metrics[:cpu_usage_rate_average],
      :mem_usage_absolute_average     => metrics[:mem_usage_absolute_average],
      :disk_usage_rate_average        => metrics[:disk_usage_rate_average]
    }
    
    Metric.create!(metric_data)
  rescue => err
    _log.error("Failed to save metrics for #{target.class.name} [#{target.name}]: #{err}")
  end
end
