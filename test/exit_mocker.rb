module ExitMocker
  class ExitException < StandardError
  end

  def exit_mocker_setup
    LxDev::System.instance_eval do
      def self.exit(exitcode = 0)
        raise ExitException
      end

    end
  end
end
