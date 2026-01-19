module ManageIQ::Providers::Proxmox
  class InfraManager::Refresher < ManageIQ::Providers::BaseManager::Refresher
    include ManageIQ::Providers::Proxmox::ManagerMixin

    def collect_inventory_for_targets(ems, targets)
      targets.map do |target|
        _log.info("Collecting inventory for #{target.class} [#{target.name}] id: [#{target.id}]")
        [target, ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager.new(ems, target)]
      end.to_h
    end

    def parse_targeted_inventory(ems, target, collector)
      _log.info("Parsing inventory for #{target.class} [#{target.name}] id: [#{target.id}]")
      persister = ManageIQ::Providers::Proxmox::Inventory::Persister::InfraManager.new(ems, target)
      parser = ManageIQ::Providers::Proxmox::Inventory::Parser::InfraManager.new(collector, persister)

      parser.parse

      persister
    end

    def post_process_refresh_classes
      []
    end
  end
end
