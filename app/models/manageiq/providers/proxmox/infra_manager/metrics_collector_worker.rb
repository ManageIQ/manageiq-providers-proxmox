class ManageIQ::Providers::Proxmox::InfraManager::MetricsCollectorWorker < ManageIQ::Providers::BaseManager::MetricsCollectorWorker
  self.default_queue_name = "proxmox"

  def friendly_name
    @friendly_name ||= "C&U Metrics Collector for Proxmox"
  end

  def self.ems_class
    ManageIQ::Providers::Proxmox::InfraManager
  end

  def self.settings_name
    :ems_metrics_collector_worker_proxmox
  end
end
