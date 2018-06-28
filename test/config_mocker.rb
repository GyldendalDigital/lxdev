module ConfigMocker
  class << self
    attr_accessor :config_file_name
  end

    def get_config_mock(config_file_name)
    LxDev::Main.class_eval do
      ConfigMocker.config_file_name = config_file_name
      alias :get_config_original :get_config
      def get_config
        YAML.load_file(ConfigMocker.config_file_name)
      end
    end

    # perform tests
    yield

    # cleanup
    LxDev::Main.class_eval do
      alias :get_config :get_config_original
    end
  end
end
