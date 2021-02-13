# This class is the model that PodBuilder uses for every pod spec. The model is instantiated
# from Pod::Specification

module PodBuilder
  class PodfileItem
    # @return [String] The git repo
    #
    attr_reader :repo

    # @return [String] The git branch
    #
    attr_reader :branch

    # @return [String] A checksum for the spec
    #
    attr_reader :checksum

    # @return [String] Matches @name unless for subspecs were it stores the name of the root pod
    #
    attr_reader :root_name

    # @return [String] The name of the pod, which might be the subspec name if appicable
    #
    attr_reader :name
    
    # @return [String] The pinned tag of the pod, if any
    #
    attr_reader :tag

    # @return [String] The pinned version of the pod, if any
    #
    attr_reader :version

    # @return Array<[String]> The available versions of the pod
    #
    attr_reader :available_versions

    # @return [String] Local path, if any
    #
    attr_accessor :path

    # @return [String] Local podspec path, if any
    #
    attr_accessor :podspec_path

    # @return [String] The pinned commit of the pod, if any
    #
    attr_reader :commit
    
    # @return [String] The module name
    #
    attr_reader :module_name
    
    # @return [String] The swift version if applicable
    #
    attr_reader :swift_version
    
    # @return [Array<String>] The pod's dependency names, if any. Use dependencies() to get the [Array<PodfileItem>]
    #
    attr_reader :dependency_names

    # @return [Array<String>] The pod's external dependency names (excluding subspecs), if any
    #
    attr_reader :external_dependency_names
    
    # @return [Bool] True if the pod is shipped as a static binary
    #
    attr_reader :is_static
    
    # @return [Array<Hash>] The pod's xcconfig configuration
    #
    attr_reader :xcconfig

    # @return [Bool] Is external pod
    #
    attr_accessor :is_external

    # @return [String] Header directory name
    #
    attr_accessor :header_dir

    # @return [String] The pod's build configuration
    #
    attr_accessor :build_configuration

    # @return [String] The pod's vendored frameworks
    #
    attr_accessor :vendored_frameworks

    # @return [String] The pod's vendored libraries
    #
    attr_accessor :vendored_libraries

    # @return [String] Framweworks the pod needs to link to
    #
    attr_accessor :frameworks

    # @return [String] Weak framweworks the pod needs to link to
    #
    attr_accessor :weak_frameworks

    # @return [String] Libraries the pod needs to link to
    #
    attr_accessor :libraries

    # @return [String] Source_files
    #
    attr_accessor :source_files

    # @return [String] License
    #
    attr_accessor :license

    # @return [String] Summary
    #
    attr_accessor :summary

    # @return [Hash] Source
    #
    attr_accessor :source

    # @return [Hash] Authors
    #
    attr_accessor :authors

    # @return [String] Homepage
    #
    attr_accessor :homepage

    # @return [Array<String>] Default subspecs
    #
    attr_accessor :default_subspecs

    # @return [Bool] Defines module
    #
    attr_accessor :defines_module
    
    # Initialize a new instance
    #
    # @param [Specification] spec
    #
    # @param [Hash] checkout_options
    #
    def initialize(spec, all_specs, checkout_options, supported_platforms)
      @name = spec.name
      @root_name = spec.name.split("/").first

      @checksum = spec.checksum

      checkout_options_keys = [@root_name, @name]

      if opts_key = checkout_options_keys.detect { |x| checkout_options.has_key?(x) }
        @repo = checkout_options[opts_key][:git]
        @tag = checkout_options[opts_key][:tag]
        @commit = checkout_options[opts_key][:commit]
        @path = checkout_options[opts_key][:path]
        @podspec_path = checkout_options[opts_key][:podspec]        
        @branch = checkout_options[opts_key][:branch]
        @is_external = true
      else
        @repo = spec.root.source[:git]
        @tag = spec.root.source[:tag]
        @commit = spec.root.source[:commit]
        @is_external = false
      end    

      @defines_module = nil # nil is not specified
      if override = spec.attributes_hash.dig("pod_target_xcconfig", "DEFINES_MODULE")
        @defines_module = (override == "YES")
      end
      
      @vendored_frameworks = extract_vendored_frameworks(spec, all_specs)
      @vendored_libraries = extract_vendored_libraries(spec, all_specs)

      @frameworks = []
      @weak_frameworks = []
      @libraries = []

      @frameworks += extract_array(spec, "framework")
      @frameworks += extract_array(spec, "frameworks")
      
      @weak_frameworks += extract_array(spec, "weak_framework")
      @weak_frameworks += extract_array(spec, "weak_frameworks")  

      @libraries += extract_array(spec, "library")
      @libraries += extract_array(spec, "libraries")  

      @header_dir = spec.attributes_hash["header_dir"]

      @version = spec.root.version.version
      @available_versions = spec.respond_to?(:spec_source) ? spec.spec_source.versions(@root_name)&.map(&:to_s) : [@version]
      
      @swift_version = spec.root.swift_version&.to_s
      @module_name = spec.root.module_name

      @default_subspecs = extract_array(spec, "default_subspecs")
      if default_subspec = spec.attributes_hash["default_subspec"]
        @default_subspecs.push(default_subspec)        
      end

      if @name == @root_name && @default_subspecs.empty?
        @default_subspecs += all_specs.select { |t| t.name.include?("/") && t.name.split("/").first == @root_name }.map { |t| t.name.split("/").last }
      end

      @dependency_names = spec.attributes_hash.fetch("dependencies", {}).keys + default_subspecs.map { |t| "#{@root_name}/#{t}" } 
      supported_platforms.each do |platform|        
        @dependency_names += (spec.attributes_hash.dig(platform, "dependencies") || {}).keys
      end
      @dependency_names.uniq!

      @external_dependency_names = @dependency_names.select { |t| !t.start_with?(root_name)  }

      @is_static = spec.root.attributes_hash["static_framework"] || false
      @xcconfig = spec.root.attributes_hash["xcconfig"] || {}

      if spec.attributes_hash.has_key?("script_phases")
        Configuration.skip_pods += [name, root_name]
        Configuration.skip_pods.uniq!
        puts "Will skip '#{root_name}' which defines script_phase in podspec".blue
      end

      default_subspecs_specs ||= begin
        subspecs = all_specs.select { |t| t.name.split("/").first == @root_name }
        subspecs.select { |t| @default_subspecs.include?(t.name.split("/").last) }
      end
      root_spec = all_specs.detect { |t| t.name == @root_name } || spec
      @source_files = source_files_from([spec, root_spec] + default_subspecs_specs)
      
      @build_configuration = spec.root.attributes_hash.dig("pod_target_xcconfig", "prebuild_configuration") || "release"
      @build_configuration.downcase!

      default_license = "MIT"
      @license = spec.root.attributes_hash.fetch("license", {"type"=>"#{default_license}"})["type"] || default_license
      @summary = spec.root.attributes_hash.fetch("summary", "A summary for #{@name}")
      @source = spec.root.attributes_hash.fetch("source", { "git"=>"https://github.com/Subito-it/PodBuilder.git" })
      @authors = spec.root.attributes_hash.fetch("authors", {"PodBuilder"=>"pod@podbuilder.com"})
      @homepage = spec.root.attributes_hash.fetch("homepage", "https://github.com/Subito-it/PodBuilder")
    end

    def pod_specification(all_poditems, parent_spec = nil)
      spec_raw = {}

      spec_raw["name"] = @name
      spec_raw["module_name"] = @module_name

      spec_raw["source"] = {}
      if repo = @repo
        spec_raw["source"]["git"] = repo
      end
      if tag = @tag
        spec_raw["source"]["tag"] = tag
      end
      if commit = @commit
        spec_raw["source"]["commit"] = commit
      end

      spec_raw["version"] = @version
      if swift_version = @swift_version
        spec_raw["swift_version"] = swift_version
      end

      spec_raw["static_framework"] = is_static

      spec_raw["frameworks"] = @frameworks
      spec_raw["libraries"] = @libraries

      spec_raw["xcconfig"] = @xcconfig

      spec_raw["dependencies"] = @dependency_names.map { |x| [x, []] }.to_h

      spec = Pod::Specification.from_hash(spec_raw, parent_spec)   
      all_subspec_items = all_poditems.select { |x| x.is_subspec && x.root_name == @name }
      spec.subspecs = all_subspec_items.map { |x| x.pod_specification(all_poditems, spec) }

      return spec
    end
    
    def inspect
      return "#{@name} repo=#{@repo} pinned=#{@tag || @commit} is_static=#{@is_static} deps=#{@dependencies || "[]"}"
    end

    def to_s
      return @name
    end

    def dependencies(available_pods)
      return available_pods.select { |x| @dependency_names.include?(x.name) }
    end

    def recursive_dependencies(available_pods)
      names = [name]

      deps = []
      last_count = -1 
      while deps.count != last_count do
        last_count = deps.count

        updated_names = []
        names.each do |name|
          if pod = available_pods.detect { |t| t.name == name }
            deps.push(pod)
            updated_names += pod.dependency_names
          end
        end
        
        names = updated_names.uniq

        deps.uniq!  
      end

      root_names = deps.map(&:root_name).uniq

      # We need to build all other common subspecs to properly build the item
      # Ex. 
      # PodA depends on DepA/subspec1
      # PodB depends on DepA/subspec2
      #
      # When building PodA we need to build both DepA subspecs because they might 
      # contain different code
      deps += available_pods.select { |t| root_names.include?(t.root_name) && t.root_name != t.name }

      deps.uniq!

      return deps
    end

    # @return [Bool] True if it's a pod that doesn't provide source code (is already shipped as a prebuilt pod)
    #    
    def is_prebuilt
      if Configuration.force_prebuild_pods.include?(@root_name) || Configuration.force_prebuild_pods.include?(@name)
        return false
      end

      # We treat pods to skip like prebuilt ones
      if Configuration.skip_pods.include?(@root_name) || Configuration.skip_pods.include?(@name)
        return true
      end

      # Podspecs aren't always properly written (source_file key is often used instead of header_files)
      # Therefore it can become tricky to understand which pods are already precompiled by boxing a .framework or .a
      embedded_as_vendored = vendored_frameworks.map { |x| File.basename(x) }.include?("#{module_name}.framework")
      embedded_as_static_lib = vendored_libraries.map { |x| File.basename(x) }.include?("lib#{module_name}.a")
      
      only_headers = (source_files.count > 0 && @source_files.all? { |x| x.end_with?(".h") })
      no_sources = (@source_files.count == 0 || only_headers) && (@vendored_frameworks + @vendored_libraries).count > 0

      if !no_sources && !only_headers
        return false
      else
        return (no_sources || only_headers || embedded_as_static_lib || embedded_as_vendored)
      end
    end

    # @return [Bool] True if it's a subspec
    #
    def is_subspec
      @root_name != @name
    end

    # @return [Bool] True if it's a development pod
    #
    def is_development_pod
      @path != nil
    end

    # @return [String] The podfile entry
    #
    def entry(include_version = true, include_pb_entry = true)
      e = "pod '#{@name}'"

      unless include_version
        return e
      end

      if is_external
        if @path
          e += ", :path => '#{@path}'"  
        elsif @podspec_path
          e += ", :podspec => '#{@podspec_path}'"  
        else
          if @repo
            e += ", :git => '#{@repo}'"  
          end
          if @tag
            e += ", :tag => '#{@tag}'"
          end
          if @commit
            e += ", :commit => '#{@commit}'"  
          end
          if @branch
            e += ", :branch => '#{@branch}'"  
          end
        end
      else
        e += ", '=#{@version}'"  
      end

      if include_pb_entry && !is_prebuilt
        prebuilt_info_path = PodBuilder::prebuiltpath("#{root_name}/#{Configuration::prebuilt_info_filename}")
        if File.exist?(prebuilt_info_path)
          data = JSON.parse(File.read(prebuilt_info_path))
          swift_version = data["swift_version"]
          is_static = data["is_static"] || false
        
          e += "#{prebuilt_marker()} is<#{is_static}>"
          if swift_version
            e += " sv<#{swift_version}>"
          end
        else
          e += prebuilt_marker()
        end
      end

      return e
    end

    def podspec_name
      return name.gsub("/", "_")
    end

    def prebuilt_rel_path
      return "#{module_name}.framework"
    end

    def prebuilt_podspec_path(absolute_path = true)
      podspec_path = PodBuilder::prebuiltpath("#{@root_name}/#{@root_name}.podspec")
      if absolute_path 
        return podspec_path
      else
        pod_path = Pathname.new(podspec_path).relative_path_from(Pathname.new(PodBuilder::basepath)).to_s
      end
    end

    def prebuilt_entry(include_pb_entry = true, absolute_path = false)
      podspec_dirname = File.dirname(prebuilt_podspec_path(absolute_path = absolute_path))

      entry = "pod '#{name}', :path => '#{podspec_dirname}'"

      if include_pb_entry && !is_prebuilt
        entry += prebuilt_marker()
      end

      return entry
    end

    def prebuilt_marker
      return " # pb<#{name}>"
    end

    def has_subspec(named)
      unless !is_subspec
        return false
      end

      return named.split("/").first == name
    end

    def has_common_spec(named)
      return root_name == named.split("/").first
    end

    private

    def extract_vendored_frameworks(spec, all_specs)
      items = []

      supported_platforms = spec.available_platforms.flatten.map(&:name).map(&:to_s)
      items += [spec.attributes_hash["vendored_frameworks"]]
      items += [spec.attributes_hash["vendored_framework"]]

      items += supported_platforms.map { |x| spec.attributes_hash.fetch(x, {})["vendored_frameworks"] }
      items += supported_platforms.map { |x| spec.attributes_hash.fetch(x, {})["vendored_framework"] }

      return items.flatten.uniq.compact
    end

    def extract_vendored_libraries(spec, all_specs)
      items = []

      supported_platforms = spec.available_platforms.flatten.map(&:name).map(&:to_s)

      items += [spec.attributes_hash["vendored_libraries"]]
      items += [spec.attributes_hash["vendored_library"]]  

      items += supported_platforms.map { |x| spec.attributes_hash.fetch(x, {})["vendored_libraries"] }
      items += supported_platforms.map { |x| spec.attributes_hash.fetch(x, {})["vendored_library"] }  

      return items.flatten.uniq.compact
    end

    def extract_array(spec, key)
      element = spec.attributes_hash.fetch(key, [])
      if element.instance_of? String
        element = [element]
      end

      return element
    end

    def source_files_from_string(source)
      # Transform source file entries 
      # "Networking{Response,Request}*.{h,m}" -> ["NetworkingResponse*.h", "NetworkingResponse*.m", "NetworkingRequest*.h", "NetworkingRequest*.m"]
      files = []
      if source.is_a? String 
        matches = source.match(/(.*){(.*)}(.*)/)
        if matches&.size == 4
          res = matches[2].split(",").map { |t| "#{matches[1]}#{t}#{matches[3]}" }
          if res.any? { |t| t.include?("{") }
            return res.map { |t| source_files_from_string(t) }.flatten
          end
  
          return res
        end

        return source.split(",")
      else
        if source.any? { |t| t.include?("{") }
          return source.map { |t| source_files_from_string(t) }.flatten
        end

        return source
      end
    end

    def source_files_from(specs)
      files = specs.map { |t| t.attributes_hash.fetch("source_files", []) }.flatten
      return source_files_from_string(files).uniq
    end
  end
end
