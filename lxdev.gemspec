# coding: utf-8
require_relative "lib/lxdev/version"

Gem::Specification.new do |spec|
  spec.name        = 'lxdev'
  spec.version     = LxDev::VERSION
  spec.date        = Time.now.strftime("%Y-%m-%d")
  spec.summary     = 'Automagic development environment with LXD'
  spec.description = 'Lightweight vagrant-like system using LXD'
  spec.authors     = ['Christian Lønaas', 'Eivind Mork']
  spec.email       = 'christian.lonaas@gyldendal.no'
  spec.homepage    = 'https://github.com/GyldendalDigital/lxdev'
  spec.license     = 'MIT'

  spec.files       = %x{git ls-files}.split("\n")
  spec.executables = %x{git ls-files -- bin/*}.split("\n").map{ |f| File.basename(f) }

  spec.add_dependency 'json', '~> 2.1'
  spec.add_dependency 'terminal-table', '~> 1.8'
end
