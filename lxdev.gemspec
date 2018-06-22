Gem::Specification.new do |spec|
  spec.name        = 'lxdev'
  spec.version     = '0.0.1'
  spec.date        = '2018-06-22'
  spec.summary     = 'Automagic development environment with LXD'
  spec.description = 'Lightweight vagrant-like system using LXD'
  spec.files       = ["lib/lxdev.rb"]
  spec.authors     = ['Christian Lønaas', 'Eivind Mork']
  spec.email       = 'christian.lonaas@gyldendal.no'
  spec.homepage    = 'https://github.com/GyldendalDigital/lxdev'
  spec.license     = 'MIT'
  spec.executables << 'lxdev'

  spec.add_dependency 'json', '~> 2.1'
  spec.add_dependency 'terminal-table', '~> 1.8'
end
