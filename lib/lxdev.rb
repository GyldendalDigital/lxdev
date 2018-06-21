require 'yaml'
require 'json'
require 'pp'
require 'pry'

class LxDev
  WHITELISTED_COMMANDS = ["lxc", "redir"]
  BOOT_TIMEOUT = 30

  def initialize
    @uid=%x{id -u}.chomp
    @gid=%x{id -g}.chomp
    @config = YAML.load_file('lxdev.yml')
    @name = @config['box']['name']
    @image = @config['box']['image']
    @user = @config['box']['user']    
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
    pp get_container_status
    puts get_container_ip
    binding.pry
  end

  def up
    unless @state.empty?
      puts "Container state .lxdev/state exists, is it running? If not it might have stopped unexpectedly. Please remove the file before starting."
      exit 1
    end
    if get_container_status.empty?
      create_container
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
    forward_ports(@config['box']['ports'])
  end

  def halt
    %x{sudo lxc stop #{@name}}
    cleanup_forwarded_ports
    remove_state
  end

  def destroy
    %x{sudo lxc delete #{@name}}
  end

  def ssh(*args)
    host = get_container_ip
    if host.nil?
      puts "#{@name} doesn't seem to be running."
      exit 1
    end
    ssh_command = "ssh -o StrictHostKeyChecking=no -t #{@user}@#{get_container_ip} bash --noprofile"
    exec ssh_command
  end

  private
  def self.lxd_initialized?
    %x{sudo lxc config show | grep 'config: {}'}
    $?.exitstatus != 0
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
    %x{sudo lxc start #{@name}}
  end

  def get_container_status
    return @status unless @status.nil?
    container_status = %x{sudo lxc list #{@name} --format=json}
    @status = JSON.parse(container_status)
  end

  def get_container_ip
    get_container_status.first['state']['network']['eth0']['addresses'].select{|addr| addr['family'] == 'inet'}.first['address']
  rescue
    nil
  end

  def add_subuid_and_subgid
    need_restart = false
    %x{sudo grep -q 'root:#{@uid}:1' /etc/subuid}
    if $?.exitstatus != 0
      %x{echo 'root:#{@uid}:1' | sudo tee -a /etc/subuid}
      need_restart = true
    end
    %x{sudo grep -q 'root:#{@gid}:1' /etc/subgid}
    if $?.exitstatus != 0
      %x{echo 'root:#{@gid}:1' | sudo tee -a /etc/subgid}
      need_restart = true
    end
    if need_restart
      %x{sudo systemctl restart lxd.service}
    end
  end

  def create_container_user(user)
    %x{sudo lxc exec #{@name} -- groupadd --gid 1001 #{user}}
    %x{sudo lxc exec #{@name} -- useradd --uid 1001 --gid 1001 -s /bin/bash -m #{user}}
    %x{sudo lxc exec #{@name} -- mkdir /home/#{user}/.ssh}
    %x{sudo lxc exec #{@name} -- chmod 0700 /home/#{user}/.ssh}
    %x{ssh-add -L | sudo lxc exec #{@name} tee /home/#{user}/.ssh/authorized_keys}
    %x{sudo lxc exec #{@name} -- chown -R #{user} /home/#{user}/.ssh}
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
      %x{sudo kill #{pid}}
    end
  end

  def map_folders(folders)
    counter = 0
    folders.each do |host, guest|
      counter = counter + 1
      puts "Mounting #{host} in #{guest}"
      absolute_path = %x{readlink -f #{host}}.chomp
      %x{sudo lxc config device add #{@name} shared_folder_#{counter} disk source=#{absolute_path} path=#{guest}}
    end
  end

  def abort_boot
    puts "Timeout waiting for container to boot"
    exit 1
  end

  def self.create_sudoers_file
  end
end
