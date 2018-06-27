require 'yaml'
require 'json'
require 'terminal-table'

class LxDev
  WHITELISTED_SUDO_COMMANDS = ["lxc", "redir", "kill"]
  SHELLS = ["bash", "zsh", "sh", "csh", "tcsh", "ash"]
  BOOT_TIMEOUT = 30
  VERSION = '0.1.1'

  def initialize
    @uid=%x{id -u}.chomp
    @gid=%x{id -g}.chomp
    @config = YAML.load_file('lxdev.yml')
    @name = @config['box']['name']
    @image = @config['box']['image']
    @user = @config['box']['user']    
    @ports = @config['box']['ports'] || {}
    Dir.mkdir('.lxdev') unless File.directory?('.lxdev')
    begin
      @state = YAML.load_file('.lxdev/state')
    rescue
      @state = Hash.new
    end
  rescue Errno::ENOENT
    puts "lxdev.yml not found"
    exit 1 
  end

  def self.setup
    unless lxd_initialized?
      puts "Please run 'lxd init' and configure LXD first"
      return false
    end
    return LxDev.new
  end

  def save_state
    File.open('.lxdev/state', 'w') {|f| f.write @state.to_yaml } unless @state.empty?
  end

  def status
    ensure_container_created

    container_status = get_container_status
    folders = container_status.first['devices'].map{|name, folders| [name,"#{folders['source']} => #{folders['path']}"] if folders['source']}.compact
    table = Terminal::Table.new do |t|
      t.add_row ['Name', container_status.first['name']]
      t.add_row ['Status', container_status.first['status']]
      t.add_row ['IP', get_container_ip]
      t.add_row ['Image', @image]
      t.add_separator
      folders.each do |folder|
        t.add_row folder
      end
      t.add_separator
      @ports.each do |guest,host|
        t.add_row ['Forwarded port', "guest: #{guest} host: #{host}"]
      end
      if container_status.first['snapshots']
        t.add_separator
        t.add_row ['Snapshots', '']
      end
      container_status.first['snapshots'].each do |snapshot|
        t.add_row [snapshot['name'].partition('/').last, snapshot['created_at']]
      end
    end
    puts table
  end

  def up
    do_provision = false
    unless @state.empty?
      puts "Container state .lxdev/state exists, is it running? If not it might have stopped unexpectedly. Please remove the file before starting."
      exit 1
    end
    if get_container_status.empty?
      create_container
      do_provision = true
    else
      if get_container_status.first['status'] == 'Running'
        puts "#{@name} is already running!"
        exit 1
      else
        start_container
      end
    end
    puts "Waiting for boot..."
    wait_for_boot
    @state['status'] = 'running'
    puts "Forwarding ports..."
    forward_ports(@ports)
    provision if do_provision
  end

  def halt
    ensure_container_created
    %x{sudo lxc stop #{@name}}
    cleanup_forwarded_ports
    remove_state
  end

  def destroy
    ensure_container_created
    %x{sudo lxc delete #{@name}}
  end

  def ssh(args)
    ensure_container_created
    host = get_container_ip
    if host.nil?
      puts "#{@name} doesn't seem to be running."
      exit 1
    end
    execute_command('ssh', "-o", "StrictHostKeyChecking=no", "-t", "#{@user}@#{get_container_ip}", *args, interactive: true)
  end

  def execute(command, interactive: false)
    if interactive
      lxc_exec(command, interactive: true)
    end
    IO.popen("sudo lxc exec #{@name} -- /bin/sh -c '#{command}'", err: [:child, :out]) do |cmd_output|
      cmd_output.each do |line|
        puts line
      end
    end
  end

  def provision
    ensure_container_created
    if get_container_status.first['status'] != 'Running'
      puts "#{@name} is not running!"
      exit 1
    end
    provisioning = @config['box']['provisioning']
    if provisioning.nil?
      puts "Nothing to do"
      return
    end
    if @config['box']['auto_snapshots']
      snapshot_name = "provision_#{Time.now.to_i}"
      snapshot(snapshot_name)
    end
    puts "Provisioning #{@name}..."
    STDOUT.sync = true
    provisioning.each do |cmd|
      execute cmd
    end
    STDOUT.sync = false
  end

  def snapshot(snapshot_name)
    puts "Creating snapshot #{snapshot_name}"
    %x{sudo lxc snapshot #{@name} #{snapshot_name}}
  end

  def restore(snapshot_name)
    puts "Restoring snapshot #{snapshot_name}"
    %x{sudo lxc restore #{@name} #{snapshot_name}}
    $?.exitstatus == 0
  end

  def rmsnapshot(snapshot_name)
    puts "Deleting snapshot #{snapshot_name}"
    %x{sudo lxc delete #{@name}/#{snapshot_name}}
    $?.exitstatus == 0
  end

  def revert
    snapshot = get_container_status.first['snapshots'].last
    snapshot_name = snapshot['name'].partition('/').last
    if restore(snapshot_name)
      puts "Reverted to snapshot #{snapshot_name}"
      puts "Deleting snapshot"
      rmsnapshot(snapshot_name)
    end
  end

  private
  def self.lxd_initialized?
    %x{sudo lxc info | grep 'lxd init'}
    $?.exitstatus != 0
  end

  def ensure_container_created
    container_status = get_container_status
    unless container_status.size > 0
      puts "Container not created yet. Run lxdev up"
      exit(0)
    end
  end

  def remove_state
    File.delete('.lxdev/state') if File.exists?('.lxdev/state')
    @state = {}
  end

  def create_container
    add_subuid_and_subgid
    puts "Launching #{@name}..."
    %x{sudo lxc init #{@image} #{@name}}
    %x{printf "uid #{@uid} 1001\ngid #{@gid} 1001"| sudo lxc config set #{@name} raw.idmap -}
    %x{sudo lxc start #{@name}}
    puts "Creating user #{@user}..."
    create_container_user(@user)
    puts "Mapping folders.."
    map_folders(@config['box']['folders'])
  end

  def start_container
    puts "Starting #{@name}..."
    execute_command('lxc', 'start', @name, sudo_privileges: true)
  end

  def get_container_status
    return @status unless @status.nil?
    container_status = execute_command('lxc', 'list', @name, '--format=json',capture_output: true, sudo_privileges: true)
    @status = JSON.parse(container_status)
  end

  def get_container_ip
    get_container_status.first['state']['network']['eth0']['addresses'].select{|addr| addr['family'] == 'inet'}.first['address']
  rescue
    nil
  end

  def add_subuid_and_subgid
    need_restart = false
    unless execute_command("grep -q 'root:#{@uid}:1' /etc/subuid")
      execute_command("echo 'root:#{@uid}:1' | sudo tee -a /etc/subuid")
      need_restart = true
    end
    unless execute_command("grep -q 'root:#{@gid}:1' /etc/subgid")
      execute_command("echo 'root:#{@gid}:1' | sudo tee -a /etc/subgid")
      need_restart = true
    end
    if need_restart
      execute_command("systemct", "restart", "lxd.service", sudo_privileges: true)
    end
  end

  def create_container_user(user)
    %x{sudo lxc exec #{@name} -- groupadd --gid 1001 #{user}}
    %x{sudo lxc exec #{@name} -- useradd --uid 1001 --gid 1001 -s /bin/bash -m #{user}}
    %x{sudo lxc exec #{@name} -- mkdir /home/#{user}/.ssh}
    %x{sudo lxc exec #{@name} -- chmod 0700 /home/#{user}/.ssh}
    %x{ssh-add -L | sudo lxc exec #{@name} tee /home/#{user}/.ssh/authorized_keys}
    %x{sudo lxc exec #{@name} -- chown -R #{user} /home/#{user}/.ssh}
    %x{sudo lxc exec #{@name} -- touch /home/#{@user}/.hushlogin}
    %x{sudo lxc exec #{@name} -- chown #{user} /home/#{user}/.hushlogin}
    %x{printf "#{user} ALL=(ALL) NOPASSWD: ALL\n" | sudo lxc exec #{@name} -- tee -a /etc/sudoers}
    %x{sudo lxc exec #{@name} -- chmod 0440 /etc/sudoers}
  end

  def wait_for_boot
    BOOT_TIMEOUT.times do |t|
      @status = nil # reset status for each iteration to refresh IP
      break if get_container_ip
      abort_boot if t == (BOOT_TIMEOUT-1)
      sleep 1
    end
  end

  def forward_ports(ports)
    redir_pids = []
    ports.each do |guest, host|
      puts "Forwarding #{get_container_ip}:#{guest} to local port #{host}"
      pid = spawn %{sudo redir --caddr=#{get_container_ip} --cport=#{guest} --lport=#{host}}
      redir_pids << pid
      Process.detach(pid)
    end
    @state['redir_pids'] = redir_pids    
  end

  def cleanup_forwarded_ports
    if @state.empty?
      return
    end
    @state['redir_pids'].each do |pid|
      execute_command('kill', pid, sudo_privileges: true)
    end
  end

  def map_folders(folders)
    counter = 0
    folders.each do |host, guest|
      counter = counter + 1
      puts "Mounting #{host} in #{guest}"
      absolute_path = execute_command("readlink", "-f", host, capture_output: true).chomp
      execute_command("lxc", "config", "device add",
                      @name, "shared_folder_#{counter}", "disk", "source=#{absolute_path}",
                      "path=#{guest}", sudo_privileges: true)
    end
  end

  def get_snapshots
    snapshots = []
    get_container_status.first['snapshots'].each do |snapshot|
      result = {}
      result['name'] = snapshot['name']
      result['date'] = snapshot['created_at']
      snapshots << result
    end
    snapshots
  end

  def lxc_exec(command, *args, interactive: false)
    execute_command("lxc", "exec", @name, command, *args, interactive: interactive, sudo_privileges: true)
  end

  def execute_command(command, *args, interactive: false, sudo_privileges: false, capture_output: false)
    if interactive
      if sudo_privileges
       exec("sudo", command, *args)
      else
        exec(command, *args)
      end
    else
      if sudo_privileges
        command = "sudo #{command}"
      end
      output = %x{#{command} #{args.join(" ")}}
      if capture_output
        return output
      else
        return $?.success?
      end
    end
  end

  def abort_boot
    puts "Timeout waiting for container to boot"
    exit 1
  end

  def self.create_sudoers_file
    user=%x{whoami}.chomp
    puts <<-EOS
!! WARNING !!
This will create a file, /etc/sudoers.d/lxdev,
which will give your user #{user} access to running
the following commands :
 #{WHITELISTED_SUDO_COMMANDS.join(" ")}
with superuser privileges. If you do not know what you're
doing, this can be dangerous and insecure.

If you want to do this, type 'yesplease'
    EOS
    action = STDIN.gets.chomp
    unless action == 'yesplease'
      puts "Not creating sudoers file"
      return
    end
    content = []
    content << "# Created by lxdev #{Time.now}"
    WHITELISTED_SUDO_COMMANDS.each do |cmd|
      cmd_with_path=%x{which #{cmd}}.chomp
      content << "#{user} ALL=(root) NOPASSWD: #{cmd_with_path}"
    end
    %x{printf '#{content.join("\n")}\n' | sudo tee /etc/sudoers.d/lxdev}
    %x{sudo chmod 0440 /etc/sudoers.d/lxdev}
    puts "Created sudoers file."
  end
end
