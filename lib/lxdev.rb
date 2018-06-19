class LxDev
  WHITELISTED_COMMANDS = ["lxc", "redir"]
  def self.setup
    unless lxd_initialized?
      puts "Please run 'lxd init' and configure LXD first"
      return false
    end
    return true
  end

  private
  def self.lxd_initialized?
    %x{sudo lxc config show | grep 'config: {}'}
    $?.exitstatus != 0
  end

  def self.create_sudoers_file
  end
end
