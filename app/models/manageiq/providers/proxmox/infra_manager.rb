class ManageIQ::Providers::Proxmox::InfraManager < ManageIQ::Providers::InfraManager
  supports :create
  supports :refresh_ems

  def self.ems_type
    @ems_type ||= "proxmox".freeze
  end

  def self.description
    @description ||= "Proxmox VE".freeze
  end

  def allow_targeted_refresh?
    true
  end

  def self.params_for_create
    {
      :fields => [
        {
          :component => 'sub-form',
          :name      => 'endpoints-subform',
          :title     => _('Endpoints'),
          :fields    => [
            {
              :component              => 'validate-provider-credentials',
              :name                   => 'authentications.default.valid',
              :skipSubmit             => true,
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
                  :validate   => [{:type => "required"}]
                },
                {
                  :component    => 'text-field',
                  :id           => 'endpoints.default.port',
                  :name         => 'endpoints.default.port',
                  :label        => _('API Port'),
                  :initialValue => 8_006,
                  :type         => 'number',
                  :validate     => [
                    {
                      :type  => 'max-number-value',
                      :value => 65_535,
                    }
                  ]
                },
                {
                  :component  => "text-field",
                  :name       => "authentications.default.userid",
                  :label      => "Username",
                  :isRequired => true,
                  :validate   => [{:type => "required"}]
                },
                {
                  :component  => "password-field",
                  :name       => "authentications.default.password",
                  :label      => "Password",
                  :type       => "password",
                  :isRequired => true,
                  :validate   => [{:type => "required"}]
                },
              ]
            }
          ]
        }
      ]
    }
  end

  def self.verify_credentials(args)
    default_endpoint = args.dig("endpoints", "default")
    hostname, port, security_protocol = default_endpoint&.values_at("hostname", "port", "security_protocol")
    verify_ssl = security_protocol == "ssl-with-validation"

    default_authentication = args.dig("authentications", "default")
    username, password = default_authentication&.values_at("userid", "password")

    password   = ManageIQ::Password.try_decrypt(password)
    password ||= find(args["id"]).authentication_password

    url = build_url(hostname, port, security_protocol)

    !!raw_connect(url, username, password, verify_ssl)
  end

  def self.build_url(host, port, security_protocol)
    scheme = security_protocol == "non-ssl" ? "http" : "https"

    URI::Generic.build(:scheme => scheme, :host => host, :port => port).to_s
  end

  def verify_credentials(auth_type = nil, options = {})
    options[:auth_type] ||= auth_type
    begin
      connect(options)
    rescue => err
      raise MiqException::MiqInvalidCredentialsError, err.message
    end

    true
  end

  def connect(options = {})
    raise MiqException::MiqHostError, "No credentials defined" if missing_credentials?(options[:auth_type])

    url      = self.class.build_url(hostname, port, security_protocol)
    username = authentication_userid(options[:auth_type])
    password = authentication_password(options[:auth_type])
    verify_ssl = security_protocol == "ssl-with-validation"

    self.class.raw_connect(url, username, password, verify_ssl)
  end

  def self.raw_connect(url, username, password, verify_ssl = true)
    require "proxmox"

    Proxmox::Client.new(
      :base_url   => url,
      :username   => username,
      :password   => password,
      :ignore_ssl => !verify_ssl
    )
  end

  def remote_console_acquire_ticket(vm, userid, originating_server, protocol = 'vnc')
    protocol = 'vnc' if protocol.to_s == 'html5'

    raise MiqException::RemoteConsoleNotSupportedError, "#{protocol} remote console is not supported" unless protocol.to_s == 'vnc'

    node_name, vmid = vm.location.split('/')

    with_provider_connection do |connection|
      vnc_response = connection.request(:post, "/nodes/#{node_name}/qemu/#{vmid}/vncproxy")
      cluster_status = connection.request(:get, "/cluster/status")
      node_data = cluster_status&.find { |item| item["type"] == "node" && item["name"] == node_name }

      SystemConsole.force_vm_invalid_token(vm.id)
      console_args = {
        :user       => User.find_by(:userid => userid),
        :vm_id      => vm.id,
        :protocol   => 'vnc',
        :secret     => vnc_response["ticket"],
        :url_secret => SecureRandom.hex,
        :ssl        => false
      }
      host_address = node_data&.dig("ip") || node_name
      host_port = vnc_response["port"].to_i

      SystemConsole.launch_proxy_if_not_local(console_args, originating_server, host_address, host_port)
    end
  rescue => err
    _log.error("VNC ticket error: #{err.message}")
    raise MiqException::RemoteConsoleNotSupportedError, err.message
  end
end
