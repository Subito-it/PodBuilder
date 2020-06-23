require 'rubygems/specification'
require 'pod_builder/rome/pre_install.rb'
require 'pod_builder/rome/post_install.rb'

module PodBuilder
  class Analyze
    # @return [Pod::Installer] The Pod::Installer instance created by processing the Podfile
    #
    def self.installer_at(path, repo_update = false)
      CLAide::Command::PluginManager.load_plugins("cocoapods")
      
      # Manually load inline podbuilder-rome plugin
      pluginspec = Gem::Specification.new("podbuilder-rome", PodBuilder::VERSION)
      pluginspec.activate

      if !CLAide::Command::PluginManager.loaded_plugins["cocoapods"].map(&:name).include?(pluginspec.name)
        CLAide::Command::PluginManager.loaded_plugins["cocoapods"].push(pluginspec)
      end

      current_dir = Dir.pwd
      Dir.chdir(path)

      config = Pod::Config.new()
      installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
      installer.repo_update = repo_update
      installer.update = false 

      installer.prepare

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
      checkout_options = external_source_pods.map { |x| [x.name.split("/").first, x.external_source] }.to_h

      # this adds the :commit which might be missing in checkout_options
      # will also overwrite :branch with :commit which is desired
      checkout_options.merge!(analyzer.sandbox.checkout_sources)
      
      all_specs = analysis_result.specifications
      
      all_podfile_items = all_specs.map { |spec| PodfileItem.new(spec, all_specs, checkout_options) }

      names = []
      analyzer.podfile.root_target_definitions[0].children.each do |children|
        names += children.dependencies.map(&:name)
      end
      names = names.uniq.sort

      podfile_pods = []
      last_count = -1 
      while podfile_pods.count != last_count do
        last_count = podfile_pods.count

        updated_names = []
        names.each do |name|
          if pod = all_podfile_items.detect { |t| t.name == name }
            podfile_pods.push(pod)
            updated_names += pod.dependency_names
          end
        end
        
        names = updated_names.uniq
        podfile_pods.uniq!
      end

      return podfile_pods.sort_by(&:name)
    end
  end
end
