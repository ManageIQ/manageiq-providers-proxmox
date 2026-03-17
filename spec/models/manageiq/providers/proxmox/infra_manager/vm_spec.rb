describe ManageIQ::Providers::Proxmox::InfraManager::Vm do
  let(:ems)  { FactoryBot.create(:ems_proxmox) }
  let(:host) { FactoryBot.create(:host_proxmox, :ext_management_system => ems) }
  let(:vm)   { FactoryBot.create(:vm_proxmox, :ext_management_system => ems, :host => host, :raw_power_state => raw_power_state, :tools_status => tools_status) }

  let(:raw_power_state) { "running" }
  let(:tools_status) { nil }

  describe "#supports?(:shutdown_guest)" do
    context "when powered off" do
      let(:raw_power_state) { "stopped" }

      it "is not available" do
        expect(vm.supports?(:shutdown_guest)).to be false
        expect(vm.unsupported_reason(:shutdown_guest)).to include("not powered on")
      end
    end

    context "when powered on" do
      let(:raw_power_state) { "running" }

      context "with the QEMU agent not running" do
        let(:tools_status) { "toolsNotRunning" }

        it "is not available" do
          expect(vm.supports?(:shutdown_guest)).to be false
          expect(vm.unsupported_reason(:shutdown_guest)).to include("agent is not running")
        end
      end

      context "with the QEMU agent not installed" do
        let(:tools_status) { "toolsNotInstalled" }

        it "is not available" do
          expect(vm.supports?(:shutdown_guest)).to be false
          expect(vm.unsupported_reason(:shutdown_guest)).to include("agent is not running")
        end
      end

      context "with the QEMU agent running" do
        let(:tools_status) { "toolsOk" }

        it "is available" do
          expect(vm.supports?(:shutdown_guest)).to be true
        end
      end
    end
  end

  describe "#supports?(:reboot_guest)" do
    context "when powered off" do
      let(:raw_power_state) { "stopped" }

      it "is not available" do
        expect(vm.supports?(:reboot_guest)).to be false
        expect(vm.unsupported_reason(:reboot_guest)).to include("not powered on")
      end
    end

    context "when suspended" do
      let(:raw_power_state) { "suspended" }

      it "is not available" do
        expect(vm.supports?(:reboot_guest)).to be false
        expect(vm.unsupported_reason(:reboot_guest)).to include("not powered on")
      end
    end

    context "when powered on" do
      let(:raw_power_state) { "running" }

      context "with the QEMU agent not running" do
        let(:tools_status) { "toolsNotRunning" }

        it "is not available" do
          expect(vm.supports?(:reboot_guest)).to be false
          expect(vm.unsupported_reason(:reboot_guest)).to include("agent is not running")
        end
      end

      context "with the QEMU agent not installed" do
        let(:tools_status) { "toolsNotInstalled" }

        it "is not available" do
          expect(vm.supports?(:reboot_guest)).to be false
          expect(vm.unsupported_reason(:reboot_guest)).to include("agent is not running")
        end
      end

      context "with the QEMU agent running" do
        let(:tools_status) { "toolsOk" }

        it "is available" do
          expect(vm.supports?(:reboot_guest)).to be true
        end
      end
    end
  end

  describe "#supports?(:reset)" do
    context "when powered off" do
      let(:raw_power_state) { "stopped" }

      it "is not available" do
        expect(vm.supports?(:reset)).to be false
        expect(vm.unsupported_reason(:reset)).to include("not powered on")
      end
    end

    context "when powered on" do
      let(:raw_power_state) { "running" }

      context "without the QEMU agent" do
        let(:tools_status) { "toolsNotInstalled" }

        it "is available" do
          expect(vm.supports?(:reset)).to be true
        end
      end

      context "with the QEMU agent running" do
        let(:tools_status) { "toolsOk" }

        it "is available" do
          expect(vm.supports?(:reset)).to be true
        end
      end
    end
  end

  describe "#supports?(:terminate)" do
    context "when powered on" do
      let(:raw_power_state) { "running" }

      it "is not available" do
        expect(vm.supports?(:terminate)).to be false
        expect(vm.unsupported_reason(:terminate)).to include("not powered off")
      end
    end

    context "when suspended" do
      let(:raw_power_state) { "suspended" }

      it "is not available" do
        expect(vm.supports?(:terminate)).to be false
        expect(vm.unsupported_reason(:terminate)).to include("not powered off")
      end
    end

    context "when powered off" do
      let(:raw_power_state) { "stopped" }

      it "is available when connected to a provider" do
        expect(vm.supports?(:terminate)).to be true
      end
    end

    context "when not connected to a provider" do
      let(:archived_vm) { FactoryBot.create(:vm_proxmox, :host => host, :raw_power_state => "stopped") }

      it "is not available" do
        expect(archived_vm.supports?(:terminate)).to be false
        expect(archived_vm.unsupported_reason(:terminate)).to include("not connected to an active Provider")
      end
    end
  end
end
