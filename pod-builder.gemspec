
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pod_builder/version'

Gem::Specification.new do |spec|
  spec.name          = "pod-builder"
  spec.version       = PodBuilder::VERSION
  spec.authors       = ["Tomas Camin"]
  spec.email         = ["tomas.camin@schibsted.com"]

  spec.summary       = %q{Prebuild CocoaPods pods}
  spec.description   = %q{Prebuild CocoaPods pods to make compiling your Xcode projects faster}
  spec.homepage      = "https://github.com/Subito-it/PodBuilder"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "ruby-debug-ide"
  spec.add_development_dependency "debase"

  spec.add_runtime_dependency 'xcodeproj'
  spec.add_runtime_dependency 'colored'
  spec.add_runtime_dependency 'highline'  
  spec.add_runtime_dependency 'cocoapods', '~> 1.6'
  spec.add_runtime_dependency 'cocoapods-core', '~> 1.6'
  spec.add_runtime_dependency 'cocoapods-rome', '~> 1.0'
  spec.add_runtime_dependency 'CFPropertyList'
end
