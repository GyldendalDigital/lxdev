require 'lxdev/container'
require 'lxdev/system'

module LxDev
  class SharedFolder
    ##
    ### For an overview of ways to mount folders in rw mode in LXC See:
    ###  https://linuxcontainers.org/lxd/docs/master/index#can-i-bind-mount-my-home-directory-in-a-container?
    ##

    @@use_shiftfs =
      !!(System.exec("lxc info |grep shiftfs| awk -F: '{ print $2 }'").output =~ /.{0,3}true.{0,3}/)

    def self.shiftfs?
      @@use_shiftfs
    end

    def self.required_uid_gid
      SharedFolder.shiftfs? &&
        [`id -u`, `id -g`]
    end

    def initialize(host, guest, container)
      @host, @guest, @container = host, guest, container
      @host = System.exec(format('readlink -f %s', @host)).output.chomp
    end

    def link_name
      format('shared_folder_%s', File.basename(@host))
    end

    def link?
      0 == System.exec(format("lxc config device ls %s |grep -q '^%s$'", @container.name, link_name)).
             exitstatus
    end

    def link
      raise('SharedFolder#system_setup has not been run yet') unless system_setup?
      unless link?
        System.exec(format('lxc config device add %s %s disk source=%s path=%s %s',
                           @container.name,
                           link_name,
                           @host,
                           @guest,
                           @@use_shiftfs ? 'shift=true' : ''))
      end
    end

    def system_setup?
      @@use_shiftfs ? system_setup_shiftfs? : system_setup_classic?
    end

    def system_setup
      raise('System is already set up.') if system_setup?
      @@use_shiftfs ? system_setup_shiftfs : system_setup_classic
    end

    private
    ##
    ### Commands for creating shared rw folders using the classic subuid/subgid trick
    ###
    ### See: https://linuxcontainers.org/lxd/docs/master/userns-idmap
    ##
    def raw_id_map(host_uid, host_gid)
      [format('uid %d %d', host_uid, @container.exec(format('id -u %s', @container.user))),
       format('gid %d %d', host_gid, @container.exec(format('id -g %s', @container.user)))].
        join("\n")
    end

    def system_setup_classic?
      host_uid, host_gid = `id -u`, `id -g`
      lxc_idmap = System.exec(format('lxc config get %s raw.idmap', @container.name)).output
      System.exec("grep -q 'root:#{host_gid}:1' /etc/subgid").exitstatus == 0 &&
        System.exec("grep -q 'root:#{host_uid}:1' /etc/subuid").exitstatus == 0 &&
        raw_id_map(host_uid, host_gid).split("\n").all?{|idmap| lxc_idmap.include?(idmap)}
    end

    def system_setup_classic
      add_subuid_and_subgid = lambda do |host_uid, host_gid|
        if System.exec("grep -q 'root:#{host_gid}:1' /etc/subgid").exitstatus != 0 ||
           System.exec("grep -q 'root:#{host_uid}:1' /etc/subuid").exitstatus != 0 then

          puts("We need root to add subuid and subgid regardless of lxc group status")
          sudo_status = System.use_sudo
          System.use_sudo = true

          need_restart = false
          if System.exec("grep -q 'root:#{host_uid}:1' /etc/subuid").exitstatus != 0
            System.exec("tee -a /etc/subuid <<EOS\nroot:#{host_uid}:1\nEOS")
            need_restart = true
          end
          if System.exec("grep -q 'root:#{host_gid}:1' /etc/subgid").exitstatus != 0
            System.exec("tee -a /etc/subgid <<EOS\nroot:#{host_gid}:1\n")
            need_restart = true
          end
          if need_restart
            begin
              System.exec("systemctl restart #{System.lxd_service_name}")
            rescue
              puts(<<~EOS)
                The LXD service needs to be restarted, but the service name cannot be detected.
                Please restart it manually.
              EOS
            end
          end

          System.use_sudo = sudo_status
        end
      end

      add_id_map = lambda do |host_uid, host_gid|
        System.exec(format('lxc config set %s raw.idmap - <<EOS\n%s\nEOS',
                           @container.name,
                           raw_id_map(host_uid, host_gid)))
      end

      host_uid, host_gid = `id -u`, `id -g`
      add_subuid_and_subgid.(host_uid, host_gid)
      add_id_map.(host_uid, host_gid)
    end

    ##
    ### Commands for creating shared rw folders using shiftfs
    ###
    ### See: https://discuss.linuxcontainers.org/t/trying-out-shiftfs/5155
    ##
    def system_setup_shiftfs?
      @container.exec(format('id -un -- %d', `id -u`)).output.chomp == @container.user
    end

    def system_setup_shiftfs
      raise("This system does not have shiftfs") unless @@use_shiftfs
      raise("The container user was not correctly set up") unless system_setup_shiftfs?
      # No setup required when the system user has the correct uid/gid.
      # See the Container#provision_user for relevant code.
    end
  end
end
