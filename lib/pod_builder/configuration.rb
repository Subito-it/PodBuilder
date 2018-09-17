require 'json'

module PodBuilder  
  class Configuration  
    # Remember to update README.md accordingly
    DEFAULT_BUILD_SETTINGS = {
      "ENABLE_BITCODE" => "NO",
      "GCC_OPTIMIZATION_LEVEL" => "s",
      "SWIFT_OPTIMIZATION_LEVEL" => "-Osize",
      "SWIFT_COMPILATION_MODE" => "singlefile",
    }.freeze
    DEFAULT_SPEC_OVERRIDE = {
      "Google-Mobile-Ads-SDK" => {
        "module_name": "GoogleMobileAds"
      }
    }.freeze
    DEFAULT_BUILD_SYSTEM = "Legacy".freeze # either Latest (New build system) or Legacy (Standard build system)
    MIN_LFS_SIZE_KB = 256.freeze
    
    private_constant :DEFAULT_BUILD_SETTINGS
    private_constant :DEFAULT_BUILD_SYSTEM
    private_constant :MIN_LFS_SIZE_KB
    
    class <<self      
      attr_accessor :build_settings
      attr_accessor :build_settings_overrides
      attr_accessor :build_system
      attr_accessor :base_path
      attr_accessor :spec_overrides      
      attr_accessor :skip_licenses
      attr_accessor :skip_pods
      attr_accessor :license_filename
      attr_accessor :subspecs_to_split
      attr_accessor :development_pods_paths
      attr_accessor :build_path
      attr_accessor :configuration_filename
      attr_accessor :dev_pods_configuration_filename
      attr_accessor :lfs_min_file_size
      attr_accessor :update_lfs_gitattributes
      attr_accessor :project_name
      attr_accessor :restore_enabled
    end
    
    @build_settings = DEFAULT_BUILD_SETTINGS
    @build_settings_overrides = {}
    @build_system = DEFAULT_BUILD_SYSTEM
    @base_path = "Frameworks" # Not nice. This value is used only for initial initization. Once config is loaded it will be an absolute path. FIXME
    @spec_overrides = DEFAULT_SPEC_OVERRIDE
    @skip_licenses = []
    @skip_pods = []
    @license_filename = "Pods-acknowledgements"
    @subspecs_to_split = []
    @development_pods_paths = []
    @build_path = "/tmp/pod_builder".freeze
    @configuration_filename = "PodBuilder.json".freeze
    @dev_pods_configuration_filename = "PodBuilderDevPodsPaths.json".freeze
    @lfs_min_file_size = MIN_LFS_SIZE_KB
    @update_lfs_gitattributes = false
    @project_name = ""
    @restore_enabled = true
    
    def self.check_inited
      raise "\n\nNot inited, run `pod_builder init`\n".red if podbuilder_path.nil?
    end
    
    def self.exists
      return !config_path.nil? && File.exist?(config_path)
    end
    
    def self.load
      unless podbuilder_path
        return
      end
      
      Configuration.base_path = podbuilder_path
      
      if exists
        json = JSON.parse(File.read(config_path))

        if value = json["spec_overrides"]
          if value.is_a?(Hash) && value.keys.count > 0
            Configuration.spec_overrides = value
          end
        end
        if value = json["skip_licenses"]
          if value.is_a?(Array) && value.count > 0
            Configuration.skip_licenses = value
          end
        end
        if value = json["skip_pods"]
          if value.is_a?(Array) && value.count > 0
            Configuration.skip_pods = value
          end
        end
        if value = json["build_settings"]
          if value.is_a?(Hash) && value.keys.count > 0
            Configuration.build_settings = value
          end
        end
        if value = json["build_settings_overrides"]
          if value.is_a?(Hash) && value.keys.count > 0
            Configuration.build_settings_overrides = value
          end
        end
        if value = json["build_system"]
          if value.is_a?(String) && ["Latest", "Legacy"].include?(value)
            Configuration.build_system = value
          end
        end
        if value = json["license_filename"]
          if value.is_a?(String) && value.length > 0
            Configuration.license_filename = value
          end
        end
        if value = json["subspecs_to_split"]
          if value.is_a?(Array) && value.count > 0
            Configuration.subspecs_to_split = value
          end
        end
        if value = json["update_lfs_gitattributes"]
          if [TrueClass, FalseClass].include?(value.class)
            Configuration.update_lfs_gitattributes = value
          end
        end
        if value = json["lfs_min_file_size_kb"]
          if value.is_a?(Integer)
            if value > 50
              Configuration.lfs_min_file_size = value
            else
              puts "\n\n⚠️ Skipping `lfs_min_file_size` value too small".yellow
            end
          end
        end
        if value = json["project_name"]
          if value.is_a?(String) && value.length > 0
            Configuration.project_name = value
          end
        end
        if value = json["restore_enabled"]
          if [TrueClass, FalseClass].include?(value.class)
            Configuration.restore_enabled = value
          end
        end
        
        Configuration.build_settings.freeze
      else
        write
      end
      
      dev_pods_configuration_path = File.join(Configuration.base_path, Configuration.dev_pods_configuration_filename)
      
      if File.exist?(dev_pods_configuration_path)
        json = JSON.parse(File.read(dev_pods_configuration_path))
        Configuration.development_pods_paths = json || []
        Configuration.development_pods_paths.freeze
      end
    end
    
    def self.write
      config = {}
      
      config["project_name"] = Configuration.project_name
      config["spec_overrides"] = Configuration.spec_overrides
      config["skip_licenses"] = Configuration.skip_licenses
      config["skip_pods"] = Configuration.skip_pods
      config["build_settings"] = Configuration.build_settings
      config["build_settings_overrides"] = Configuration.build_settings_overrides
      config["build_system"] = Configuration.build_system
      config["license_filename"] = Configuration.license_filename
      config["subspecs_to_split"] = Configuration.subspecs_to_split
      config["update_lfs_gitattributes"] = Configuration.update_lfs_gitattributes
      config["lfs_min_file_size_kb"] = Configuration.lfs_min_file_size
      
      File.write(config_path, JSON.pretty_generate(config))
    end
    
    private 
    
    def self.config_path
      unless path = podbuilder_path
        return nil
      end
      
      return File.join(path, Configuration.configuration_filename)
    end
    
    def self.podbuilder_path
      paths = Dir.glob("#{PodBuilder::home}/**/.pod_builder")
      raise "\n\nToo many .pod_builder found `#{paths.join("\n")}`\n".red if paths.count > 1
      
      return paths.count > 0 ? File.dirname(paths.first) : nil
    end
  end  
end
