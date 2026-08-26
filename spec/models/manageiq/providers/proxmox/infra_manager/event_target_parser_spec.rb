describe ManageIQ::Providers::Proxmox::InfraManager::EventTargetParser do
  let(:ems)          { FactoryBot.create(:ems_proxmox) }
  let(:host)         { FactoryBot.create(:host_proxmox, :ext_management_system => ems, :ems_ref => host_uid_ems) }
  let(:ems_event)    { FactoryBot.create(:ems_event, :ext_management_system => ems, :host => host, :vm_ems_ref => vm_ems_ref) }
  let(:host_uid_ems) { "pve-node1" }
  let(:parser)       { described_class.new(ems_event) }

  describe "#parse" do
    context "when event contains both vm_ems_ref and host_uid_ems" do
      let(:vm_ems_ref) { "100" }

      it "returns targets for both VM and host" do
        targets = parser.parse

        expect(targets.count).to eq(2)

        vm_target = targets.find { |t| t.association == :vms_and_templates }
        expect(vm_target).to be_present
        expect(vm_target.manager_ref).to eq({:ems_ref => "100"})

        host_target = targets.find { |t| t.association == :hosts }
        expect(host_target).to be_present
        expect(host_target.manager_ref).to eq({:ems_ref => "pve-node1"})
      end
    end

    context "when event contains only vm_ems_ref" do
      let(:vm_ems_ref) { "200" }
      let(:host)       { nil }

      it "returns only VM target" do
        targets = parser.parse

        expect(targets.count).to eq(1)

        vm_target = targets.first
        expect(vm_target.association).to eq(:vms_and_templates)
        expect(vm_target.manager_ref).to eq({:ems_ref => "200"})
      end
    end

    context "when event contains only host" do
      let(:vm_ems_ref) { nil }

      it "returns only host target" do
        targets = parser.parse

        expect(targets.count).to eq(1)

        host_target = targets.first
        expect(host_target.association).to eq(:hosts)
        expect(host_target.manager_ref).to eq({:ems_ref => host.ems_ref})
      end
    end

    context "when event contains neither vm_ems_ref nor host_uid_ems" do
      let(:vm_ems_ref) { nil }
      let(:host)       { nil }

      it "returns empty targets" do
        targets = parser.parse

        expect(targets).to be_empty
      end
    end

    context "when vm_ems_ref is an empty string" do
      let(:vm_ems_ref) { "" }

      it "returns only host target" do
        targets = parser.parse

        expect(targets.count).to eq(1)

        host_target = targets.first
        expect(host_target.association).to eq(:hosts)
        expect(host_target.manager_ref).to eq({:ems_ref => host.ems_ref})
      end
    end

    context "when host ems_ref is an empty string" do
      let(:vm_ems_ref) { "300" }
      let(:host_uid_ems) { "" }

      it "returns only VM target" do
        targets = parser.parse

        expect(targets.count).to eq(1)

        vm_target = targets.first
        expect(vm_target.association).to eq(:vms_and_templates)
        expect(vm_target.manager_ref).to eq({:ems_ref => "300"})
      end
    end

    context "when both vm_ems_ref and host_uid_ems are empty strings" do
      let(:vm_ems_ref) { "" }
      let(:host_uid_ems) { "" }

      it "returns empty targets" do
        targets = parser.parse

        expect(targets).to be_empty
      end
    end
  end
end
