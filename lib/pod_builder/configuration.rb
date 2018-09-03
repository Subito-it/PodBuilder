require 'json'

module PodBuilder  
  class Configuration    
    class <<self      
      attr_accessor :build_settings
      attr_accessor :build_settings_overrides
      attr_accessor :build_system
      attr_accessor :base_path
      attr_accessor :spec_overrides      
      attr_accessor :skip_licenses
      attr_accessor :license_filename
      attr_accessor :subspecs_to_split
      attr_accessor :development_pods_paths
      attr_accessor :build_path
      attr_accessor :configuration_filename
      attr_accessor :dev_pods_configuration_filename
    end

    # Remember to update README.md
    @build_settings = {
      "ONLY_ACTIVE_ARCH" => "NO", 
      "ENABLE_BITCODE" => "NO",
      "CLANG_ENABLE_MODULE_DEBUGGING" => "NO",
      "GCC_OPTIMIZATION_LEVEL" => "s",
      "SWIFT_OPTIMIZATION_LEVEL" => "-Osize",
      "SWIFT_COMPILATION_MODE" => "singlefile",
    }  
    @build_settings_overrides = {}
    @build_system = "Legacy" # either Latest (New build system) or Legacy (Standard build system)    
    @base_path = "Frameworks" # Not nice. This value is used only for initial initization. Once config is loaded it will be an absolute path. FIXME
    @spec_overrides = {}
    @skip_licenses = []
    @license_filename = "Pods-acknowledgements"
    @subspecs_to_split = []
    @development_pods_paths = []
    @build_path = "/tmp/pod_builder".freeze
    @configuration_filename = "PodBuilder.json".freeze
    @dev_pods_configuration_filename = "PodBuilderDevPodsPaths.json".freeze
    
    def self.check_inited
      raise "\n\nNot inited, run `pod_builder init`\n".red if podbuilder_path.nil?
    end
    
    def self.exists
      return File.exist?(config_path)
    end
    
    def self.load
      unless podbuilder_path
        return
      end

      Configuration.base_path = podbuilder_path

      if exists
        json = JSON.parse(File.read(config_path))
        if json.has_key?("spec_overrides")
          Configuration.spec_overrides = json["spec_overrides"]
        end
        if json.has_key?("skip_licenses")
          Configuration.skip_licenses = json["skip_licenses"]
        end
        if json.has_key?("build_settings")
          Configuration.build_settings = json["build_settings"]
        end
        if json.has_key?("build_settings_overrides")
          Configuration.build_settings_overrides = json["build_settings_overrides"]
        end
        if json.has_key?("build_system")
          Configuration.build_system = json["build_system"]
        end
        if json.has_key?("license_filename")
          Configuration.license_filename = json["license_filename"]
        end
        if json.has_key?("subspecs_to_split")
          Configuration.subspecs_to_split = json["subspecs_to_split"]
        end

        Configuration.build_settings.freeze
      end

      if File.exist?(Configuration.dev_pods_configuration_filename)
        json = JSON.parse(File.read(Configuration.dev_pods_configuration_filename))
        if json.has_key?("development_pods_paths")
          Configuration.development_pods_paths = json["development_pods_paths"]
        end

        Configuration.development_pods_paths.freeze
      end
    end
    
    def self.write
      config = {
        # nothing here yet
      }
      File.write(config_path, config.to_json)
    end

    private 
    
    def self.config_path
      unless p = podbuilder_path
        return nil
      end

      return File.join(podbuilder_path, Configuration.configuration_filename)
    end

    def self.podbuilder_path
      paths = Dir.glob("#{PodBuilder::home}/**/.pod_builder")
      raise "\n\nToo many .pod_builder found `#{paths.join("\n")}`\n".red if paths.count > 1

      return paths.count > 0 ? File.dirname(paths.first) : nil
    end
  end  
end
