require 'lxdev/container'
require 'lxdev/system'

module LxDev
  class Redir
    attr_reader :guest, :host

    @@aux_command = <<~BASH
      ps axo pid,args | \
      grep -vP '(grep)%{no_sudo}' | \
      grep -P 'redir\s+%{host}\s+%{ip}\s+%{guest}' | \
      awk '{ print $1 }'
    BASH

    def initialize(guest, host, container)
      @guest, @host, @container = guest, host, container
      @is_sudo = false
      @ip = @container.ip
      refresh_state
    end

    def running?
      @state && @state != 0
    end

    def start
      return unless @container.running?
      @ip = @container.ip
      System.spawn_exec(cmd)
      refresh_state
      raise(format('Failed to start redir (Host: %d, Guest: %d)', host, guest)) unless running?
    end

    def stop
      if running? && (result = System.exec(format('kill %d', @state))).exitstatus != 0
        raise(format('Failed to stop redir with message: %s', result.output))
      end
      refresh_state
    end

    private
    def cmd
      raise('Redir does not have any ip yet') unless @ip
      format('redir :%d %s:%d ', @host, @ip, @guest)
    end

    def refresh_state
      return unless @ip
      @state = System.exec(format(@@aux_command, no_sudo: '|(sudo)', host: @host, ip: @ip, guest: @guest)).
                 output.to_i
      unless running?
        @state = System.exec(format(@@aux_command, no_sudo: '', host: @host, ip: @ip, guest: @guest)).
                   output.to_i
        @is_sudo = !!@state
      end
    end
  end
end
