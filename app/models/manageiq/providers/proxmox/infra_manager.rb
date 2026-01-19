module ManageIQ::Providers
  class Proxmox::InfraManager < ManageIQ::Providers::InfraManager

    include ManageIQ::Providers::Proxmox::ManagerMixin
    supports :create
    supports :provisioning
    supports :refresh_new_target
    supports :refresh_ems
    supports :reconfigure_disks


    def self.ems_type
      @ems_type ||= "proxmox".freeze
    end

    def self.description
      @description ||= "Proxmox VE".freeze
    end

    def self.hostname_required?
      true
    end

    def self.display_name(number = 1)
      n_('Infrastructure Provider (Proxmox)', 'Infrastructure Providers (Proxmox)', number)
    end

    def self.catalog_types
      {"proxmox" => N_("Proxmox")}
    end

    def self.default_port
      8006
    end

    def self.params_for_create
      {
        :fields => [
          {
            :component => 'sub-form',
            :id        => 'endpoints-subform',
            :name      => 'endpoints-subform',
            :title     => _('Endpoints'),
            :fields    => [
              {
                :component              => 'validate-provider-credentials',
                :id                     => 'authentications.default.valid',
                :name                   => 'authentications.default.valid',
                :skipSubmit             => true,
                :isRequired             => true,
                :validationDependencies => %w[type zone_id],
                :fields                 => [
                  {
                    :component    => "select",
                    :id           => "endpoints.default.security_protocol",
                    :name         => "endpoints.default.security_protocol",
                    :label        => _("Security Protocol"),
                    :isRequired   => true,
                    :initialValue => 'ssl-with-validation',
                    :validate     => [{:type => "required"}],
                    :options      => [
                      {
                        :label => _("SSL without validation"),
                        :value => "ssl-no-validation"
                      },
                      {
                        :label => _("SSL"),
                        :value => "ssl-with-validation"
                      },
                      {
                        :label => _("Non-SSL"),
                        :value => "non-ssl"
                      }
                    ]
                  },
                  {
                    :component  => "text-field",
                    :id         => "endpoints.default.hostname",
                    :name       => "endpoints.default.hostname",
                    :label      => _("Hostname (or IPv4 or IPv6 address)"),
                    :isRequired => true,
                    :validate   => [{:type => "required"}],
                  },
                  {
                    :component    => "text-field",
                    :id           => "endpoints.default.port",
                    :name         => "endpoints.default.port",
                    :label        => _("API Port"),
                    :type         => "number",
                    :initialValue => default_port,
                    :isRequired   => true,
                    :validate     => [{:type => "required"}],
                  },
                  {
                    :component  => "text-field",
                    :id         => "authentications.default.userid",
                    :name       => "authentications.default.userid",
                    :label      => _("Username"),
                    :helperText => _("Should have privileged access, such as root@pam"),
                    :isRequired => true,
                    :validate   => [{:type => "required"}],
                  },
                  {
                    :component  => "password-field",
                    :id         => "authentications.default.password",
                    :name       => "authentications.default.password",
                    :label      => _("Password"),
                    :type       => "password",
                    :isRequired => true,
                    :validate   => [{:type => "required"}],
                  },
                ],
              },
            ],
          },
        ],
      }
    end

    def self.verify_credentials(args)
      _log.info("=== PROXMOX DEBUG: verify_credentials called ===")
      _log.info("Args received: #{args.inspect}")

      default_endpoint = args.dig("endpoints", "default")
      hostname, port, security_protocol = default_endpoint&.values_at("hostname", "port", "security_protocol")

      authentication = args.dig("authentications", "default")
      userid, password = authentication&.values_at("userid", "password")

      port ||= default_port
      verify_ssl = security_protocol == "ssl-with-validation"

      _log.info("Extracted values:")
      _log.info("  - hostname: #{hostname}")
      _log.info("  - port: #{port}")
      _log.info("  - security_protocol: #{security_protocol}")
      _log.info("  - verify_ssl: #{verify_ssl}")
      _log.info("  - userid: #{userid}")

      # Decrypt password if necessary
      if password && password.start_with?("v2:")
        _log.info("Password is encrypted, decrypting...")
        password = ManageIQ::Password.decrypt(password)
        _log.info("Password decrypted successfully")
      else
        password = ManageIQ::Password.try_decrypt(password)
        password ||= find(args["id"])&.authentication_password if args["id"]
      end

      unless userid&.include?("@")
        _log.warn("Username does not contain realm, adding @pam")
        userid = "#{userid}@pam"
      end

      _log.info("Final userid with realm: #{userid}")

      result = raw_connect(hostname, port, userid, password, verify_ssl)
      _log.info("Connection successful!")

      !!result
    rescue => err
      _log.error("=== PROXMOX ERROR in verify_credentials ===")
      _log.error("Error class: #{err.class}")
      _log.error("Error message: #{err.message}")
      _log.error("Backtrace: #{err.backtrace.first(10).join("\n")}")
      raise
    end

    def connect(options = {})
      raise MiqException::MiqHostError, _("No credentials defined") if missing_credentials?(options[:auth_type])

      username = authentication_userid(options[:auth_type])
      password = authentication_password(options[:auth_type])
      hostname = address
      port     = self.port || self.class.default_port
      verify_ssl = security_protocol == "ssl-with-validation"

      unless username.include?("@")
        username = "#{username}@pam"
      end

      connection_data = self.class.raw_connect(hostname, port, username, password, verify_ssl)
      ProxmoxClient.new(connection_data)
    end

    def verify_credentials(auth_type = nil, options = {})
      begin
        connect(options.merge(:auth_type => auth_type))
      rescue => err
        raise MiqException::MiqInvalidCredentialsError, err.message
      end

      true
    end

    def vm_reconfigure(vm, options = {})
      log_header = "EMS: [#{name}] #{vm.class.name}: id [#{vm.id}], name [#{vm.name}], ems_ref [#{vm.ems_ref}]"
      spec = options[:spec]

      _log.info("#{log_header} VM Reconfigure Started...")
      _log.info("#{log_header} Spec: #{spec.inspect}")

      connection = connect
      
      # Gérer différents formats de ems_ref
      if vm.ems_ref.to_s.include?('/')
        node_id, vmid = vm.ems_ref.split('/')
      else
        # Si ems_ref ne contient que le VMID, récupérer le node depuis le host
        vmid = vm.ems_ref
        node_id = vm.host&.ems_ref || vm.host&.name
        
        _log.info("#{log_header} ems_ref does not contain node, using host: #{node_id}")
      end
      
      raise MiqException::MiqVmError, _("Cannot determine Proxmox node (node_id=#{node_id.inspect}, vmid=#{vmid.inspect})") unless node_id && vmid
      
      _log.info("#{log_header} Proxmox node: #{node_id}, VM ID: #{vmid}")
            
      config_updates = {}

      if spec['memory']
        config_updates['memory'] = spec['memory']
        _log.info("#{log_header} Setting memory to #{spec['memory']} MB")
      end

      if spec['cores'] || spec['sockets']
        config_updates['cores'] = spec['cores'] if spec['cores']
        config_updates['sockets'] = spec['sockets'] if spec['sockets']
        
        _log.info("#{log_header} Setting CPU to #{spec['sockets']} sockets × #{spec['cores']} cores")
      end

      disks_to_edit = spec['disksEdit'] || spec['disksResize']
      if disks_to_edit && disks_to_edit.any?
        _log.info("#{log_header} Editing disks: #{disks_to_edit.inspect}")
        edit_vm_disks(connection, node_id, vmid, disks_to_edit, log_header)
      end

      if spec['disksAdd']
        _log.info("#{log_header} Adding disks: #{spec['disksAdd'].inspect}")
        add_vm_disks(connection, node_id, vmid, spec['disksAdd'], log_header)
      end

      if spec['disksRemove']
        _log.info("#{log_header} Removing disks: #{spec['disksRemove'].inspect}")
        remove_vm_disks(connection, node_id, vmid, spec['disksRemove'], log_header)
      end

      unless config_updates.empty?
        _log.info("#{log_header} Applying configuration: #{config_updates.inspect}")
        connection.put("nodes/#{node_id}/qemu/#{vmid}/config", config_updates)
           # Refresh immédiat de la VM pour mettre à jour les données dans ManageIQ  
        _log.info("#{log_header} Refreshing VM after reconfiguration...")
       EmsRefresh.queue_refresh(self)
      end
      
      _log.info("#{log_header} VM Reconfigure Completed.")
      
      true
      rescue => err
        _log.error("#{log_header} VM reconfiguration failed: #{err}")
        _log.error(err.backtrace.join("\n"))
        raise MiqException::MiqVmError, _("An error occurred while reconfiguring the VM: %{error}") % {:error => err}
    end

  def edit_vm_disks(connection, node_id, vmid, disks_specs, log_header)
    _log.info("#{log_header} edit_vm_disks: #{disks_specs.inspect}")
    
    disks_specs.each do |disk_spec|
      disk_spec = disk_spec.symbolize_keys
      disk_name = disk_spec[:disk_name]
      new_size_mb = disk_spec[:disk_size_in_mb].to_i
      new_size_gb = (new_size_mb / 1024.0).ceil
      
      _log.info("#{log_header} Resizing disk #{disk_name} to #{new_size_gb}GB")
      
      begin
        response = connection.put(
          "nodes/#{node_id}/qemu/#{vmid}/resize",
          disk: disk_name,
          size: "#{new_size_gb}G"
        )
        
        _log.info("#{log_header} Disk #{disk_name} resized successfully: #{response.inspect}")
      rescue => err
        _log.error("#{log_header} Error resizing disk #{disk_name}: #{err}")
        raise MiqException::MiqVmError, "Failed to resize disk #{disk_name}: #{err}"
      end
    end
  end

  def add_vm_disks(connection, node_id, vmid, disks_specs, log_header)
    _log.warn("#{log_header} Adding disks not yet implemented")
  end

  def remove_vm_disks(connection, node_id, vmid, disks_specs, log_header)
    _log.warn("#{log_header} Removing disks not yet implemented")
  end

    def vm_set_memory(vm, options = {})
      spec = { 'memoryMB' => options[:value] }
      vm_reconfigure(vm, :spec => spec)
    end

    def vm_set_num_cpus(vm, options = {})
      cpu_total = options[:value]
      spec = { 'numCPUs' => cpu_total }
      cpu_cores = vm.cpu_cores_per_socket || 1
      cpu_sockets = cpu_total / cpu_cores
      spec['numCoresPerSocket'] = cpu_cores if cpu_sockets >= 1
      vm_reconfigure(vm, :spec => spec)
    end

    def self.build_url(host, port, security_protocol)
      scheme = security_protocol == "non-ssl" ? "http" : "https"
      URI::Generic.build(:scheme => scheme, :host => host, :port => port).to_s
    end

    def self.raw_connect(hostname, port, username, password, verify_ssl = false)
      _log.info("=== PROXMOX raw_connect ===")
      _log.info("Connecting to: https://#{hostname}:#{port}")
      _log.info("Username: #{username}")
      _log.info("Verify SSL: #{verify_ssl}")

      require 'rest-client'
      require 'json'
      require 'uri'

      url = "https://#{hostname}:#{port}/api2/json"

      _log.info("Attempting authentication...")

      auth_response = RestClient::Request.execute(
        method: :post,
        url: "#{url}/access/ticket",
        payload: URI.encode_www_form({
          username: username,
          password: password
        }),
        headers: {
          content_type: 'application/x-www-form-urlencoded'
        },
        verify_ssl: verify_ssl,
        timeout: 30,
        open_timeout: 10
      )

      _log.info("Auth response status: #{auth_response.code}")

      auth_data = JSON.parse(auth_response.body)

      unless auth_data['data'] && auth_data['data']['ticket']
        _log.error("Invalid response from Proxmox: #{auth_data.inspect}")
        raise MiqException::MiqInvalidCredentialsError, "No ticket received from Proxmox"
      end

      _log.info("Authentication successful!")

      {
        url:        url,
        ticket:     auth_data['data']['ticket'],
        csrf_token: auth_data['data']['CSRFPreventionToken'],
        verify_ssl: verify_ssl
      }
    rescue RestClient::Unauthorized => err
      _log.error("Authentication failed (401 Unauthorized)")
      _log.error("Response body: #{err.response&.body || 'N/A'}")
      raise MiqException::MiqInvalidCredentialsError,
            _("Login failed due to a bad username or password.")
    rescue RestClient::Exception => err
      _log.error("RestClient error: #{err.class} - #{err.message}")
      _log.error("Response code: #{err.response&.code || 'N/A'}")
      _log.error("Response body: #{err.response&.body || 'N/A'}")
      raise MiqException::MiqInvalidCredentialsError,
            _("Login failed: %{error}") % {:error => err.message}
    rescue => err
      _log.error("Unexpected error: #{err.class} - #{err.message}")
      _log.error("Backtrace: #{err.backtrace.first(5).join("\n")}")
      raise MiqException::MiqHostError,
            _("Unable to connect: %{error}") % {:error => err.message}
    end

    # Proxmox API Client
    class ProxmoxClient
      attr_reader :url, :ticket, :csrf_token, :verify_ssl

      def initialize(connection_data)
        @url = connection_data[:url]
        @ticket = connection_data[:ticket]
        @csrf_token = connection_data[:csrf_token]
        @verify_ssl = connection_data[:verify_ssl]
      end

      def get(path)
        require 'rest-client'
        require 'json'

        path = path.sub(/^\//, '')

        response = RestClient::Request.execute(
          method: :get,
          url: "#{@url}/#{path}",
          headers: {
            'Cookie' => "PVEAuthCookie=#{@ticket}"
          },
          verify_ssl: @verify_ssl,
          timeout: 60
        )

        result = JSON.parse(response.body)
        result['data']
      rescue RestClient::Exception => err
        ManageIQ::Providers::Proxmox::InfraManager._log.error("API call failed for #{path}: #{err.message}")
        raise
      end

      def post(path, payload = {})
        require 'rest-client'
        require 'json'

        path = path.sub(/^\//, '')

        response = RestClient::Request.execute(
          method: :post,
          url: "#{@url}/#{path}",
          payload: payload,
          headers: {
            'Cookie' => "PVEAuthCookie=#{@ticket}",
            'CSRFPreventionToken' => @csrf_token
          },
          verify_ssl: @verify_ssl,
          timeout: 60
        )

        result = JSON.parse(response.body)
        result['data']
      rescue RestClient::Exception => err
        ManageIQ::Providers::Proxmox::InfraManager._log.error("API POST failed for #{path}: #{err.message}")
        raise
      end

      def put(path, payload = {})
        require 'rest-client'
        require 'json'

        path = path.sub(/^\//, '')

        response = RestClient::Request.execute(
          method: :put,
          url: "#{@url}/#{path}",
          payload: payload,
          headers: {
            'Cookie' => "PVEAuthCookie=#{@ticket}",
            'CSRFPreventionToken' => @csrf_token
          },
          verify_ssl: @verify_ssl,
          timeout: 60
        )

        result = JSON.parse(response.body)
        result['data']
        rescue RestClient::Exception => err
          ManageIQ::Providers::Proxmox::InfraManager._log.error("API PUT failed for #{path}: #{err.message}")
          raise
      end

      def delete(path)
        require 'rest-client'
        require 'json'

        path = path.sub(/^\//, '')

        response = RestClient::Request.execute(
          method: :delete,
          url: "#{@url}/#{path}",
          headers: {
            'Cookie' => "PVEAuthCookie=#{@ticket}",
            'CSRFPreventionToken' => @csrf_token
          },
          verify_ssl: @verify_ssl,
          timeout: 60
        )

        result = JSON.parse(response.body)
        result['data']
      rescue RestClient::Exception => err
        ManageIQ::Providers::Proxmox::InfraManager._log.error("API DELETE failed for #{path}: #{err.message}")
        raise
      end

      def nodes
        @nodes ||= NodesCollection.new(self)
      end

      def cluster
        @cluster ||= ClusterCollection.new(self)
      end

      class ClusterCollection
        def initialize(client)
          @client = client
        end

        def resources
          # Get all cluster resources
          @client.get('cluster/resources') || []
        end

        def status
          @client.get('cluster/status')
        end

        def wait_for_task(upid, timeout = 300)
          return unless upid
          
          start_time = Time.now
          
          while (Time.now - start_time) < timeout
            task_data = @client.get("cluster/tasks/#{upid}")
            
            # get returns result['data'], which may be an array or a hash
            task_data = task_data.first if task_data.is_a?(Array)
            
            return unless task_data
            
            status = task_data['status']
            return if status == 'stopped' # Completed
            raise _("Task failed: %{exitstatus}") % {:exitstatus => task_data['exitstatus']} if status == 'failed'
            
            sleep(2) # Poll every 2 seconds
          end
          
          raise _("Task timeout after %{timeout} seconds") % {:timeout => timeout}
        end
      end

      class NodesCollection
        def initialize(client)
          @client = client
        end

        def all
          @client.get('nodes')
        end

        def get(node_name)
          Node.new(@client, node_name)
        end
      end

      class Node
        def initialize(client, name)
          @client = client
          @name = name
        end

        def qemu
          QemuCollection.new(@client, @name)
        end

        def lxc
          LxcCollection.new(@client, @name)
        end

        def storage
          @client.get("nodes/#{@name}/storage")
        end

        def network
          @client.get("nodes/#{@name}/network")
        end
      end

      class QemuCollection
        def initialize(client, node_name)
          @client = client
          @node_name = node_name
        end

        def all
          @client.get("nodes/#{@node_name}/qemu")
        end

        def get(vmid)
          @client.get("nodes/#{@node_name}/qemu/#{vmid}/config")
        end
      end

      class LxcCollection
        def initialize(client, node_name)
          @client = client
          @node_name = node_name
        end

        def all
          @client.get("nodes/#{@node_name}/lxc")
        end

        def get(vmid)
          @client.get("nodes/#{@node_name}/lxc/#{vmid}/config")
        end
      end
    end
  end
end
