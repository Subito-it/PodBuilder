require 'pod_builder/cocoapods/specification'

module PodBuilder
  class Analyze
    # @return [Pod::Installer] The Pod::Installer instance created by processing the Podfile
    #
    def self.installer_at(path, repo_update = false)
      CLAide::Command::PluginManager.load_plugins("cocoapods")

      current_dir = Dir.pwd
      Dir.chdir(path)

      config = Pod::Config.new()
      installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
      installer.repo_update = repo_update
      installer.update = false 

      analyzer = installer.resolve_dependencies

      Dir.chdir(current_dir)

      return installer, analyzer
    end
    
    # @return [Array<PodfileItem>] The PodfileItem in the Podfile (including subspecs) and dependencies
    #
    def self.podfile_items(installer, analyzer)
      sandbox = installer.sandbox
      analysis_result = installer.analysis_result
      
      all_podfile_pods = analysis_result.podfile_dependency_cache.podfile_dependencies

      external_source_pods = all_podfile_pods.select(&:external_source)
      checkout_options = external_source_pods.map { |x| [x.name, x.external_source] }.to_h

      # this adds the :commit which might be missing in checkout_options
      # will also overwrite :branch with :commit which is desired
      checkout_options.merge!(analyzer.sandbox.checkout_sources)
      
      all_specs = analysis_result.specifications

      all_podfile_specs = all_specs.select { |x| all_podfile_pods.map(&:name).include?(x.name) }

      deps_names = all_podfile_specs.map { |x| x.recursive_dep_names(all_specs) }.flatten.uniq

      all_podfile_specs += all_specs.select { |x| deps_names.include?(x.name) }
      all_podfile_specs.uniq!
      
      return all_podfile_specs.map { |spec| PodfileItem.new(spec, all_specs, checkout_options) }
    end
  end
end
