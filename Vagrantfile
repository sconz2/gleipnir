# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Gleipnir: sandboxed VMs for Claude Code, one per project. See README.md.
#
# Each file in machines/ defines one VM, named after the file:
#   machines/my-project.json  ->  vagrant up my-project
#
# This file only creates the VMs and hands over to install.sh, which does the
# real work and is the same entry point used on a VPS.

require 'json'

root = File.expand_path(__dir__)

# Where each VM receives the scripts, config and key: a folder only vagrant can read
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

  key = nil
  if settings['deploy_key']
    key = File.expand_path(settings['deploy_key'], root)
    abort "Gleipnir: #{where}: deploy key not found at #{key}." unless File.exist?(key)
  end

  ports = settings['ports'] || {}
  {
    name: name,
    file: file,
    settings: settings,
    key: key,
    editor_port: ports.fetch('editor', 8080),
    app_port: ports.fetch('app', 5173)
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

      machine.vm.provider 'virtualbox' do |vb|
        vb.name = "gleipnir-#{m[:name]}"
        vb.memory = vm_settings.fetch('memory', 3072)
        vb.cpus = vm_settings.fetch('cpus', 2)
      end

      # Upload Gleipnir's scripts, this machine's config and its deploy key
      machine.vm.provision 'shell', name: 'Gleipnir: preparing upload',
        inline: "rm -rf #{upload} && install -d -m 0700 -o vagrant -g vagrant #{upload}"
      machine.vm.provision 'file', source: File.join(root, 'install.sh'), destination: "#{upload}/install.sh"
      machine.vm.provision 'file', source: File.join(root, 'scripts'), destination: "#{upload}/scripts"
      machine.vm.provision 'file', source: m[:file], destination: "#{upload}/config.json"
      machine.vm.provision 'file', source: m[:key], destination: "#{upload}/deploy_key" if m[:key]

      # The same entry point as on a VPS
      install_args = "#{upload}/config.json"
      install_args += " #{upload}/deploy_key" if m[:key]
      machine.vm.provision 'shell', name: 'Gleipnir: install', inline: "bash #{upload}/install.sh #{install_args}"

      # Tidy up: the key now lives only in dev's home inside the VM
      machine.vm.provision 'shell', name: 'Gleipnir: cleaning up', inline: "rm -rf #{upload}"
    end
  end
end
