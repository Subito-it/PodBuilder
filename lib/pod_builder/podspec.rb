module PodBuilder
  class Podspec
    class PodspecItem
      attr_accessor :name
      attr_accessor :module_name
      attr_accessor :vendored_frameworks
      attr_accessor :vendored_items
      attr_accessor :frameworks
      attr_accessor :weak_frameworks
      attr_accessor :libraries
      attr_accessor :resources
      attr_accessor :exclude_files
      attr_accessor :xcconfig
      attr_accessor :dependencies
      
      def initialize
        @name = ""
        @module_name = ""
        @vendored_frameworks = []
        @vendored_items = []
        @frameworks = []
        @weak_frameworks = []
        @libraries = []
        @resources = []
        @exclude_files = []
        @xcconfig = {}
        @dependencies = []
      end
      
      def to_s
        @name
      end
    end
    private_constant :PodspecItem
    
    def self.generate(all_buildable_items, analyzer)  
      unless all_buildable_items.count > 0
        return
      end
      
      puts "Generating PodBuilder's local podspec".yellow
                  
      podspec_items = podspec_items_from(all_buildable_items)

      platform = analyzer.instance_variable_get("@result").targets.first.platform
      generate_podspec_from(podspec_items, platform)
    end

    def self.include?(pod_name)
      podspec_path = PodBuilder::basepath("PodBuilder.podspec")
      unless File.exist?(podspec_path)
        return false
      end

      if Configuration.subspecs_to_split.include?(pod_name)
        pod_name = pod_name.gsub("/", "_")
      else
        pod_name = pod_name.split("/").first
      end

      podspec_content = File.read(podspec_path)

      # (_.*) will include prebuild podnames like s.subspec 'Podname_Subspec' do |p|
      subspec_regex = "s.subspec '#{pod_name}(_.*)?' do |p|" 
      return (podspec_content.match(/#{subspec_regex}/) != nil)
    end
    
    private

    def self.generate_podspec_from(podspec_items, platform)
      podspecs = []
      podspec_items.each do |item|
        vendored_frameworks = item.vendored_frameworks.map { |x| x.vendored_framework_path }.compact
        vendored_frameworks += item.vendored_items.map { |x| File.basename(x) }.select { |x| File.exist?(PodBuilder::basepath(PodfileItem::vendored_name_framework_path(x))) }.map { |x| "Rome/#{x}" }
        vendored_frameworks.uniq!
        vendored_libraries = Dir.glob(PodBuilder::basepath("Rome/#{item.module_name}/**/*.a")).map { |x| x.to_s.gsub(PodBuilder::basepath, "")[1..-1] }

        non_prebuilt_dependencies = item.dependencies.select { |x| x.vendored_framework_path.nil? }
        
        podspec = "  s.subspec '#{item.name.gsub("/", "_")}' do |p|\n"

        if vendored_frameworks.count > 0
          podspec += "    p.vendored_frameworks = '#{vendored_frameworks.join("','")}'\n"
        end
        if vendored_libraries.count > 0
          podspec += "    p.vendored_libraries = '#{vendored_libraries.join("','")}'\n"
        end
        if item.frameworks.count > 0
          podspec += "    p.frameworks = '#{item.frameworks.join("', '")}'\n"
        end
        if item.libraries.count > 0
          podspec += "    p.libraries = '#{item.libraries.join("', '")}'\n"
        end
        if item.resources.count > 0
          podspec += "    p.resources = '#{item.resources.join("', '")}'\n"
        end
        if item.resources.count > 0
          podspec += "    p.exclude_files = '#{item.exclude_files.join("', '")}'\n"
        end
        if item.xcconfig.keys.count > 0
          podspec += "    p.xcconfig = #{item.xcconfig.to_s}\n"
        end
        non_prebuilt_dependencies.each do |non_prebuilt_dependency|
          podspec += "    p.dependency '#{non_prebuilt_dependency.name}'\n"
        end

        podspec += "  end"
        
        podspecs.push(podspec)
      end
      
      cwd = File.dirname(File.expand_path(__FILE__))
      podspec_file = File.read("#{cwd}/templates/build_podspec.template")
      podspec_file.gsub!("%%%podspecs%%%", podspecs.join("\n\n"))
            
      podspec_file.sub!("%%%platform_name%%%", platform.name.to_s)
      podspec_file.sub!("%%%deployment_version%%%", platform.deployment_target.version)
      
      File.write(PodBuilder::basepath("PodBuilder.podspec"), podspec_file)
    end

    def self.podspec_items_from(buildable_items)
      podspec_items = []

      buildable_items.each do |pod|
        spec_exists = File.exist?(PodBuilder::basepath(pod.vendored_spec_framework_path))
        subspec_exists = File.exist?(PodBuilder::basepath(pod.vendored_subspec_framework_path))
        
        unless spec_exists || subspec_exists
          puts "Skipping `#{pod.name}`, not prebuilt".blue
          next
        end
        
        pod_name = Configuration.subspecs_to_split.include?(pod.name) ? pod.name : pod.root_name
        unless podspec_item = podspec_items.detect { |x| x.name == pod_name }
          podspec_item = PodspecItem.new
          podspec_items.push(podspec_item)
          podspec_item.name = pod_name
          podspec_item.module_name = pod.module_name
          podspec_item.vendored_items = pod.vendored_items
        end
        
        podspec_item.vendored_frameworks += [pod] + pod.dependencies(buildable_items)
        
        podspec_item.frameworks = podspec_item.vendored_frameworks.map { |x| x.frameworks }.flatten.uniq.sort
        podspec_item.weak_frameworks = podspec_item.vendored_frameworks.map { |x| x.weak_frameworks }.flatten.uniq.sort
        podspec_item.libraries = podspec_item.vendored_frameworks.map { |x| x.libraries }.flatten.uniq.sort
        
        static_vendored_frameworks = podspec_item.vendored_frameworks.select { |x| x.is_static }

        podspec_item.resources = static_vendored_frameworks.map { |x| x.vendored_framework_path.nil? ? nil : "#{x.vendored_framework_path}/*.{nib,bundle,xcasset,strings,png,jpg,tif,tiff,otf,ttf,ttc,plist,json,caf,wav,p12,momd}" }.compact.flatten.uniq
        podspec_item.exclude_files = static_vendored_frameworks.map { |x| x.vendored_framework_path.nil? ? nil : "#{x.vendored_framework_path}/Info.plist" }.compact.flatten.uniq
        podspec_item.exclude_files += podspec_item.vendored_frameworks.map { |x| x.vendored_framework_path.nil? ? nil : "#{x.vendored_framework_path}/#{Configuration.framework_plist_filename}" }.compact.flatten.uniq.sort

        # Merge xcconfigs
        if !pod.xcconfig.empty?
          pod.xcconfig.each do |k, v|
            unless v != "$(inherited)"
              next
            end
            unless k == "OTHER_LDFLAGS"
              next # For the time being limit to OTHER_LDFLAGS key
            end

            if podspec_values = podspec_item.xcconfig[k]
              podspec_values_arr = podspec_values.split(" ")
              podspec_values_arr.push(v)
              v = podspec_values_arr.join(" ")          
            end
            
            podspec_item.xcconfig[k] = v
          end
        end

        podspec_item.dependencies = buildable_items.select { |x| pod.dependency_names.include?(x.name) }
      end

      return podspec_items
    end
  end
end