require 'json'

module PodBuilder  
  class Configuration
    DEV_PODS_CONFIG_FILE = "PodBuilderDevelopmentPods.json".freeze
    CONFIG_FILE = "PodBuilder.json".freeze
    BUILD_PATH = "/tmp/pod_builder".freeze
    
    private_constant :CONFIG_FILE
    private_constant :BUILD_PATH

    class <<self      
      attr_accessor :build_settings
      attr_accessor :build_settings_overrides
      attr_accessor :build_system
      attr_accessor :base_path
      attr_accessor :spec_overrides      
      attr_accessor :skip_licenses
      attr_accessor :license_file_name
      attr_accessor :subspecs_to_split
      attr_accessor :development_pods_paths
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
    @license_file_name = "Pods-acknowledgements"
    @subspecs_to_split = []
    @development_pods_paths = []
    
    def self.check_inited
      count = Dir.glob("#{File.dirname(config_path)}/**/.pod_builder").count
      raise "\n\nNot inited, run `pod_builder init`\n".red if count == 0
      raise "\n\nToo many .pod_builder found `#{count}`\n".red if count > 1
    end

    def self.build_path
      return BUILD_PATH
    end
    
    def self.exists
      return File.exist?(config_path)
    end
    
    def self.load
      unless config_path
        return
      end

      Configuration.base_path = File.dirname(config_path)

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
        if json.has_key?("license_file_name")
          Configuration.license_file_name = json["license_file_name"]
        end
        if config.has_key?("development_pods_paths")
          Configuration.development_pods_paths = config["development_pods_paths"]
        if json.has_key?("subspecs_to_split")
          Configuration.subspecs_to_split = json["subspecs_to_split"]
        end

        Configuration.build_settings.freeze
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
      PodBuilder::find_xcodeproj

      unless PodBuilder::project_path
        return
      end

      if File.expand_path(base_path) == base_path # absolute
        path = base_path
      else
        path = "#{PodBuilder::project_path}/#{base_path}"  
      end

      return File.join(path, CONFIG_FILE)
    end
  end  
end
