# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Gleipnir: sandboxed VMs for Claude Code, one per project. See README.md.
#
# Each file in machines/ defines one VM, named after the file:
#   machines/my-project.json  ->  vagrant up my-project
#
# Its other files are found by the same name, unless its config points elsewhere:
#   keys/my-project      the repo's deploy key (needed for SSH repo URLs), or "deploy_key"
#   env/my-project.env   the project's .env (optional), or "env_file"
#
# This file only creates the VMs and hands over to install.sh, which does the
# real work and is the same entry point used on a VPS.

require 'json'

root = File.expand_path(__dir__)

# A bare `vagrant destroy` would destroy every machine, and each one holds the only
# copy of its unpushed work and its database. Make it name the machines it destroys.
words = ARGV.reject { |arg| arg.start_with?('-') }
if words.first == 'destroy' && words.size == 1
  abort 'Gleipnir: name the machine to destroy, e.g. vagrant destroy my-project'
end

# Where each VM receives the scripts, config, key and .env: a folder only vagrant can read
upload = '/home/vagrant/.gleipnir'

# --- Read every machine config ------------------------------------------------
machines = Dir.glob(File.join(root, 'machines', '*.json')).sort.map do |file|
  name = File.basename(file, '.json')
  where = "machines/#{name}.json"

  unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    abort "Gleipnir: #{where}: use only lowercase letters, digits and dashes in the file name."
  end

  begin
    settings = JSON.parse(File.read(file))
  rescue JSON::ParserError => e
    abort "Gleipnir: #{where} isn't valid JSON: #{e.message}"
  end

  abort "Gleipnir: #{where}: \"repo\" is required." if settings['repo'].to_s.strip.empty?

  # A machine's other files: the path its config gives (relative to this folder),
  # otherwise the default named after the machine. A path the config gives must exist.
  find = lambda do |setting, default|
    if settings[setting]
      path = File.expand_path(settings[setting], root)
      abort "Gleipnir: #{where}: #{setting} not found at #{path}." unless File.file?(path)
      path
    else
      path = File.join(root, default)
      File.file?(path) ? path : nil
    end
  end

  # The deploy key: keys/<name>. SSH repo URLs can't be cloned without one.
  key = find.call('deploy_key', "keys/#{name}")
  if key.nil? && settings['repo'].match?(%r{\A(ssh://|[^/@:]+@[^:]+:)})
    abort "Gleipnir: #{where}: no deploy key at keys/#{name}. Create one with:\n" \
          "  ssh-keygen -t ed25519 -f keys/#{name} -C \"#{name} VM\" -N \"\""
  end

  # The project's .env: env/<name>.env, if there is one
  env_file = find.call('env_file', "env/#{name}.env")

  ports = settings['ports'] || {}
  postgres = settings['postgres'] || {}
  {
    name: name,
    file: file,
    settings: settings,
    key: key,
    env_file: env_file,
    editor_port: ports.fetch('editor', 8080),
    app_port: ports.fetch('app', 5173),
    db_port: postgres['enabled'] == true ? ports.fetch('db', 54320) : nil
  }
end

if machines.empty?
  abort 'Gleipnir: no machines yet. Copy machines/example.json.example to machines/<name>.json and fill it in.'
end

# --- Two VMs can't share a port on your computer ------------------------------
owners = Hash.new { |hash, port| hash[port] = [] }
machines.each do |m|
  owners[m[:editor_port]] << "#{m[:name]} (editor)"
  owners[m[:app_port]] << "#{m[:name]} (app)"
  owners[m[:db_port]] << "#{m[:name]} (database)" if m[:db_port]
end
clashes = owners.select { |_port, users| users.size > 1 }
unless clashes.empty?
  details = clashes.map { |port, users| "port #{port} is used by #{users.join(' and ')}" }.join('; ')
  abort "Gleipnir: #{details}. Give each machine its own \"ports\" in its config."
end

Vagrant.require_version '>= 2.4'

Vagrant.configure('2') do |config|
  config.vm.box = 'bento/ubuntu-24.04'

  # Nothing from your computer is shared into the VMs. Each project lives on its VM's own disk.
  config.vm.synced_folder '.', '/vagrant', disabled: true

  machines.each do |m|
    # autostart: false, so a bare `vagrant up` doesn't boot every machine at once
    config.vm.define m[:name], autostart: false do |machine|
      vm_settings = m[:settings]['vm'] || {}
      machine.vm.hostname = m[:name]

      # The editor and the app, reachable only from your computer's own localhost
      machine.vm.network 'forwarded_port', guest: 8080, host: m[:editor_port], host_ip: '127.0.0.1'
      machine.vm.network 'forwarded_port', guest: 5173, host: m[:app_port], host_ip: '127.0.0.1'
      if m[:db_port]
        machine.vm.network 'forwarded_port', guest: 5432, host: m[:db_port], host_ip: '127.0.0.1'
      end

      machine.vm.provider 'virtualbox' do |vb|
        vb.name = "gleipnir-#{m[:name]}"
        vb.memory = vm_settings.fetch('memory', 3072)
        vb.cpus = vm_settings.fetch('cpus', 2)
      end

      # Upload Gleipnir's scripts, this machine's config, deploy key and .env
      machine.vm.provision 'shell', name: 'Gleipnir: preparing upload',
        inline: "rm -rf #{upload} && install -d -m 0700 -o vagrant -g vagrant #{upload}"
      machine.vm.provision 'file', source: File.join(root, 'install.sh'), destination: "#{upload}/install.sh"
      machine.vm.provision 'file', source: File.join(root, 'scripts'), destination: "#{upload}/scripts"
      machine.vm.provision 'file', source: m[:file], destination: "#{upload}/config.json"
      machine.vm.provision 'file', source: m[:key], destination: "#{upload}/deploy_key" if m[:key]
      machine.vm.provision 'file', source: m[:env_file], destination: "#{upload}/env" if m[:env_file]

      # The same entry point as on a VPS. An empty argument means "none".
      install_args = [
        "#{upload}/config.json",
        m[:key] ? "#{upload}/deploy_key" : '',
        m[:env_file] ? "#{upload}/env" : ''
      ].map { |arg| "\"#{arg}\"" }.join(' ')
      machine.vm.provision 'shell', name: 'Gleipnir: install', inline: "bash #{upload}/install.sh #{install_args}"

      # Tidy up: the key and .env now live only where install.sh put them
      machine.vm.provision 'shell', name: 'Gleipnir: cleaning up', inline: "rm -rf #{upload}"

      # Copy just the .env, without a full provision. These only run when asked for:
      #   vagrant provision my-project --provision-with env-upload,env
      if m[:env_file]
        staged = '/home/vagrant/.gleipnir-env'
        machine.vm.provision 'env-upload', type: 'file', run: 'never',
          source: m[:env_file], destination: staged
        machine.vm.provision 'env', type: 'shell', run: 'never', inline: <<~SHELL
          set -e
          trap 'rm -f #{staged}' EXIT
          if [ ! -d /srv/project ]; then
            echo "Gleipnir: the project isn't set up yet; run a full provision first." >&2
            exit 1
          fi
          install -o dev -g project -m 0640 #{staged} /srv/project/.env
          echo "Gleipnir: .env copied into the project"
          # Restart the dev server, if it's running, so it picks up the change
          devserver try-restart 2>/dev/null || true
        SHELL
      end
    end
  end
end