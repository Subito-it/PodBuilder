
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pod_builder/version'

Gem::Specification.new do |spec|
  spec.name          = "pod-builder"
  spec.version       = PodBuilder::VERSION
  spec.authors       = ["Tomas Camin"]
  spec.email         = ["tomas.camin@adevinta.com"]

  spec.summary       = %q{Prebuild CocoaPods pods}
  spec.description   = %q{Prebuild CocoaPods pods to make compiling your Xcode projects faster}
  spec.homepage      = "https://github.com/Subito-it/PodBuilder"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features|Example)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = '>= 2.6'

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", ">= 12.3.3"
  spec.add_development_dependency "ruby-debug-ide", '0.6.1'
  spec.add_development_dependency "debase", '0.2.2'

  spec.add_runtime_dependency 'xcodeproj'
  spec.add_runtime_dependency 'colored'
  spec.add_runtime_dependency 'highline'  
  spec.add_runtime_dependency 'cocoapods', '~> 1.6'
  spec.add_runtime_dependency 'cocoapods-core', '~> 1.6'
  spec.add_runtime_dependency 'CFPropertyList'
  spec.add_runtime_dependency 'json'
end
