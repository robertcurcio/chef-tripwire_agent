property :installer,                    String, name_property: true
property :console,                      String
property :services_password,            String
property :console_port,                 Integer, default: 9898
property :install_directory,            [String, nil], default: nil
property :install_rtm,                  [true, false], default: true
property :rtm_port,                     Integer, default: 1169
property :proxy_agent,                  [true, false], default: false
property :proxy_hostname,               [String, nil], default: nil
property :proxy_port,                   Integer, default: 1080
property :fips,                         [true, false], default: false
property :integration_port,             Integer, default: 8080
property :start_service,                [true, false], default: true
property :tags,                         Hash, default: {}
property :removeall,                    [true, false], default: true

default_action :install

action :install do
  # Set platform specific installer settings
  if node['platform'] == 'windows'
    ext = '.msi'
    def_install = 'C:\Program Files\Tripwire\TE\Agent'
    service_name = 'teagent'
    package_name = 'Tripwire Enterprise Agent'
    is_agent_installed = is_package_installed?(package_name)
  else
    ext = '.bin'
    def_install = '/usr/local/tripwire/te/agent'
    service_name = 'twdaemon'
    package_name = 'TWeagent'
    is_agent_installed = node['packages'].keys.include?(package_name)
  end

  # Set local cache target for the installer
  local_installer = ::Chef::Config['file_cache_path'] + '/te_agent' + ext

  # Set the correct header for remote_file
  installer_source_path = if installer.start_with?('http')
                            installer
                          else
                            'file:///' + installer
                          end

  # Download installer
  remote_file local_installer do
    source installer_source_path
    mode '744' unless node['platform'] == 'windows'
  end

  # Set the installer options for windows or linux
  options_array = []
  if node['platform'] == 'windows'
    options_array << local_installer +
                     ' /qn' \
                     ' ACCEPT_EULA=true' \
                     ' TE_SERVER_HOSTNAME=' + console +
                     ' TE_SERVER_PORT=' + console_port.to_s +
                     ' SERVICES_PASSWORD=' + services_password +
                     ' INSTALL_RTM=' + install_rtm.to_s

    if install_directory != def_install
      options_array << 'INSTALLDIR=' + install_directory
    end
    if proxy_hostname
      options_array << 'TE_PROXY_HOSTNAME=' + proxy_hostname
      options_array << 'TE_PROXY_PORT=' + proxy_port.to_s if proxy_port != 1080
    end
    options_array << 'RTMPORT=' + rtm_port.to_s if install_rtm && rtm_port != 1169
    if fips
      options_array << 'INSTALL_FIPS=true'
      if integration_port != 8080
        options_array << 'TE_SERVER_HTTP_PORT=' + integration_port
      end
    end
    options_array << 'START_AGENT=false'
  else
    options_array << local_installer +
                     ' --silent' \
                     ' --eula accept' \
                     ' --server-host ' + console +
                     ' --server-port ' + console_port.to_s +
                     ' --passphrase ' + services_password +
                     ' --install-rtm ' + install_rtm.to_s

    if install_directory != def_install
      if node['platform'] == 'debian' || node['platform'] == 'ubuntu'
        raise 'Remove custom install directory, agent must use the default install path on this platform'
      else
        options_array << '--install-dir ' + install_directory
      end
    end
    if proxy_hostname
      options_array << '--proxy-host ' + proxy_hostname
      options_array << '--proxy-port ' + proxy_port.to_s if proxy_port != 1080
    end
    options_array << '--rtmport ' + rtm_port.to_s if install_rtm && rtm_port != 1169
    if fips
      options_array << '--enable-fips'
      options_array << '--http-port ' + integration_port.to_s if integration_port != 1080
    end
  end
  cmd_str = options_array.join(' ')

  # Install Tripwire Enterprise Java agent
  execute 'Install Tripwire Enterprise java agent' do
    command cmd_str
    not_if { is_agent_installed }
  end

  template install_directory + '/data/config/agent.tags.conf' do
    source 'java_tags.erb'
    variables(tmpl_tags: tags)
    not_if { tags.empty? }
  end

  # Editing config file to make the Java agent into a proxy
  ruby_block 'Adding proxy settings to TE Agent' do
    block do
      pxy = Chef::Util::FileEdit.new(install_directory + '/data/config/agent.properties')
      pxy.search_file_replace_line(/bootstrapables=station/, 'space.bootstrapables=station,socksProxy')
      pxy.insert_line_after_match(/tw\.server.port/, 'tw.proxy.serverPort=' + proxy_port.to_s)
      pxy.write_file
    end
    only_if { proxy_agent }
  end

  # Start the agent's service
  if start_service
    service service_name do
      action :start
    end
  else
    log 'Agent service has not been started per chef setting.' do
      level :warn
    end
  end
end

# Include the Windows cookbook's helper methods
action_class.class_eval do
  include Windows::Helper
end

action :remove do
  # Set platform specific installer settings
  # Note: is_agent_installed should use ohai to check if the tripwire package
  # is installed, in testing ohai didnt reload reliably to determine if the
  # package existed causing the guard to prevent the removal of the agent
  if node['platform'] == 'windows'
    install_path = if install_directory != 'C:\Program\ Files\Tripwire\TE\Agent'
                     install_directory
                   else
                     'C:\Program Files\Tripwire\TE\Agent'
                   end
    service_name = 'teagent'
    uninstaller = 'uninstall.cmd'
    is_agent_installed = ::File.exist?(install_path + '/bin/twdaemon.cmd')
  else
    install_path = if install_directory != '/usr/local/tripwire/te/agent'
                     install_directory
                   else
                     '/usr/local/tripwire/te/agent'
                   end
    service_name = 'twdaemon'
    uninstaller = './uninstall.sh'
    is_agent_installed = ::File.exist?(install_path + '/bin/twdaemon')
  end

  # Stop java services
  service service_name do
    action :stop
  end

  # Remove the Java Agent
  execute 'Uninstall Tripwire Java Agent' do
    uninstall_cmd = if removeall
                      log 'Removing all files from agent install directory'
                      uninstaller + ' --removeall --force'
                    else
                      log 'Uninstall will leave some files on the system'
                      uninstaller
                    end
    command uninstall_cmd
    cwd install_path + '/bin'
    only_if { is_agent_installed }
  end

  # Reload systemctl to remove reference to twrtmd
  execute 'systemctl daemon-reload' do
    only_if { platform_family?('rhel') && node['platform_version'].to_f >= 7.0 || platform_family?('debian') }
  end
end