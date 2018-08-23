require 'json'

module PodBuilder  
  class Configuration
    class <<self
      attr_accessor :config_file
      attr_accessor :base_path
      attr_accessor :build_path
      attr_accessor :build_settings
      attr_accessor :build_system
      attr_accessor :spec_overrides
      attr_accessor :skip_licenses
      attr_accessor :license_file_name
    end

    @config_file = "PodBuilder.json"
    @base_path = "Frameworks"
    @build_path = "/tmp/pod_builder"
    @spec_overrides = {}
    @skip_licenses = []
    @build_settings = { "ENABLE_BITCODE" => "NO",
                        "CLANG_ENABLE_MODULE_DEBUGGING" => "NO",
                        "GCC_OPTIMIZATION_LEVEL" => "s",
                        "SWIFT_OPTIMIZATION_LEVEL" => "-Osize",
                      }  
    @build_system = "Latest" # either Latest (New build system) or Legacy (Standard build system)
    @license_file_name = "Pods-acknowledgements"               

    def self.check_inited
      count = Dir.glob("#{PodBuilder::home}/**/.pod_builder").count
      raise "\n\nNot inited, run `pod_builder init`\n".red if count == 0
      raise "\n\nToo many .pod_builder found `#{count}`\n".red if count > 1
    end
    
    def self.exists
      return config_path ? File.exist?(config_path) : false
    end
    
    def self.load
      unless config_path
        return
      end

      Configuration.base_path = File.dirname(config_path)

      if exists
        config = JSON.parse(File.read(config_path))
        Configuration.spec_overrides = config["spec_overrides"] || []
        Configuration.skip_licenses = config["skip_licenses"] || []
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
      unless PodBuilder::xcodepath
        return
      end

      project_path = "#{PodBuilder::xcodepath}/#{base_path}/.pod_builder"
      config_path = Dir.glob("#{PodBuilder::home}/**/.pod_builder").first
      
      path = File.dirname(config_path || project_path)
      return File.join(path, config_file)
    end
  end  
end
