require "minitest/autorun"
require 'pry'
require 'exec_mocker'
require 'config_mocker'
require 'exit_mocker'
require 'lxdev/main'
require 'pp'

class LxDevTest < Minitest::Test
  include ExecMocker
  include ConfigMocker
  include ExitMocker

  def setup
    @lxc_list_for_container_testing = File.read("test/fixtures/lxc_list_for_container_testing.json")
    @lxc_list_for_container_huba    = File.read("test/fixtures/lxc_list_for_container_huba.json")
    exit_mocker_setup
  end


  def test_status_with_container
    exec_mock_setup = {
        "sudo lxc info | grep 'lxd init'"     => {
            result:     '',
            exitstatus: 1
        },
        "id -u"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "id -g"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "ssh-add -L"                          => {
            result:     'ssh-rsa SSHKEYDATA /home/user/.ssh/id_rsa',
            exitstatus: 0
        },
        "sudo lxc list testing --format=json" => {
            result:     @lxc_list_for_container_testing,
            exitstatus: 0
        }
    }

    get_config_mock('test/fixtures/testing_config.yml') do
      system_exec_mock(exec_mock_setup) do
        lxdev = LxDev::Main.setup()
        lxdev.status()
        assert_output(/testing/) {lxdev.status()}
        assert_output(/\/home\/user\/lxdev/) {lxdev.status()}
        assert_output(/\/home\/testing\/lxdev/) {lxdev.status()}
        assert_output(/ubuntu:bionic /) {lxdev.status()}
        assert_output(/10\.221\.79\.46/) {lxdev.status()}
        assert_output(/guest: 80 host: 9999/) {lxdev.status()}

        assert_equal 5, ExecMocker.calls.size
        assert_equal ["sudo lxc info | grep 'lxd init'",
                      "id -u",
                      "id -g",
                      "ssh-add -L",
                      "sudo lxc list testing --format=json"], ExecMocker.calls
      end
    end
  end


  def test_status_with_no_container
    # We have one container, but not the one we are looking for
    # Container 'huba' is present, but not 'testing' which
    # we are looking for
    exec_mock_setup = {
        "sudo lxc info | grep 'lxd init'"     => {
            result:     '',
            exitstatus: 1
        },
        "id -u"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "id -g"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "ssh-add -L"                          => {
            result:     'ssh-rsa SSHKEYDATA /home/user/.ssh/id_rsa',
            exitstatus: 0
        },
        "sudo lxc list testing --format=json" => {
            result:     "[]",
            exitstatus: 0
        }
    }

    get_config_mock('test/fixtures/testing_config.yml') do
      system_exec_mock(exec_mock_setup) do
        lxdev = LxDev::Main.setup()
        assert_raises (ExitMocker::ExitException) do
          assert_output(/Container not created yet. Run lxdev up/) {lxdev.status()}
        end
      end
    end
  end

  def test_lxd_not_initialized
    # We have one container, but not the one we are looking for
    # Container 'huba' is present, but not 'testing' which
    # we are looking for
    exec_mock_setup = {
        "sudo lxc info | grep 'lxd init'"     => {
            result:     'If this is your first time running LXD on this machine, you should also run: lxd init
To start your first container, try: lxc launch ubuntu:16.04',
            exitstatus: 0
        },
        "id -u"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "id -g"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "ssh-add -L"                          => {
            result:     'ssh-rsa SSHKEYDATA /home/user/.ssh/id_rsa',
            exitstatus: 0
        },
        "sudo lxc list testing --format=json" => {
            result:     "[]",
            exitstatus: 0
        }
    }

    get_config_mock('test/fixtures/testing_config.yml') do
      system_exec_mock(exec_mock_setup) do
        lxdev = nil
        assert_output(/Please run 'lxd init' and configure LXD first/) { lxdev = LxDev::Main.setup() }

        assert_equal false, lxdev # Can't initialize
      end
    end
  end

  def test_uo
    exec_mock_setup = {
        "sudo lxc info | grep 'lxd init'"     => {
            result:     '',
            exitstatus: 1
        },
        "id -u"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "id -g"                               => {
            result:     '1000',
            exitstatus: 0
        },
        "ssh-add -L"                          => {
            result:     'ssh-rsa SSHKEYDATA /home/user/.ssh/id_rsa',
            exitstatus: 0
        },
        "sudo lxc list testing --format=json" => {
            result:     @lxc_list_for_container_testing,
            exitstatus: 0
        }
    }

    get_config_mock('test/fixtures/testing_config.yml') do
      system_exec_mock(exec_mock_setup) do
        lxdev = LxDev::Main.setup()
        ExecMocker.calls = []


        assert_raises (ExitMocker::ExitException) do
          assert_output(/Container not created yet. Run sssssslxdev up/) { lxdev.up() }
        end

        pp ExecMocker.calls
        # assert_output(/testing/) {lxdev.status()}
        # assert_output(/\/home\/user\/lxdev/) {lxdev.status()}
        # assert_output(/\/home\/testing\/lxdev/) {lxdev.status()}
        # assert_output(/ubuntu:bionic /) {lxdev.status()}
        # assert_output(/10\.221\.79\.46/) {lxdev.status()}
        # assert_output(/guest: 80 host: 9999/) {lxdev.status()}
        #
        # assert_equal 5, ExecMocker.calls.size
        # assert_equal ["sudo lxc info | grep 'lxd init'",
        #               "id -u",
        #               "id -g",
        #               "ssh-add -L",
        #               "sudo lxc list testing --format=json"], ExecMocker.calls
      end
    end
  end
end
