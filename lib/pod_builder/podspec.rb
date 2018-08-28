module PodBuilder
  class Podspec
    def self.generate     
      buildable_items = Podfile.podfile_items_at(PodBuilder::basepath("Podfile"))

      grouped_buildable_items = buildable_items.select { |x| x.is_subspec }.group_by { |x| x.root_name }

      grouped_buildable_items.each do |root_name, subspecs|
        unless !buildable_items.map(&:name).include?(root_name)
          next
        end

        spec_raw = {}
        all_specs = []
        checkout_options = {}
        
        spec_raw["name"] = root_name
        spec_raw["module_name"] = root_name

        # spec_raw["source"] = ["git": "https://www.subito.it/pod/#{root_name}.git", "tag": "1.0"]
        spec_raw["source"] = []

        deps = subspecs.map { |x| x.dependencies(buildable_items) }.flatten.uniq
        spec_raw["dependencies"] = deps.map { |x| [x.root_name, []] }.to_h
        
        spec_raw["static_framework"] = subspecs.map(&:is_static).reduce(true) { |result, item| result && item }

        if subspecs.map(&:xcconfig).select { |x| !x.empty? }.count > 0 
          raise "Unhandled subspec xcconfig. Please open issue https://github.com/Subito-it/PodBuilder/issues"
        end
        
        spec = Pod::Specification.from_string(spec_raw.to_json, "podspec.json")        

        pod = PodfileItem.new(spec, all_specs, checkout_options)
        buildable_items.push(pod)
      end

      buildable_items.sort_by! { |x| x.name }

      podspecs = []
      buildable_items.each do |pod|
        spec_exists = File.exist?(PodBuilder::basepath(vendored_spec_framework_path(pod))) 
        subspec_exists = File.exist?(PodBuilder::basepath(vendored_subspec_framework_path(pod)))
        
        unless spec_exists || subspec_exists
          puts "Skipping #{pod.name}, not prebuilt".blue
          next
        end

        vendored_frameworks = [pod] + pod.dependencies(buildable_items)

        static_vendored_frameworks = vendored_frameworks.select { |x| x.is_static }
        framework_paths = vendored_frameworks.map { |x| vendored_framework_path(x) }.compact
        
        podspec = "  s.subspec '#{pod.podspec_name}' do |p|\n"
        podspec += "    p.vendored_frameworks = '#{framework_paths.uniq.join("','")}'\n"
        
        podspec_resources = static_vendored_frameworks.map { |x| "#{vendored_framework_path(x)}/*.{nib,bundle,xcasset,strings,png,jpg,tif,tiff,otf,ttf,ttc,plist,json,caf,wav,p12,momd}" }
        if podspec_resources.count > 0
          podspec += "    p.resources = '#{podspec_resources.uniq.join("','")}'\n"
        end
        
        podspec_exclude_files = static_vendored_frameworks.map { |x| "#{vendored_framework_path(x)}/Info.plist" }
        if podspec_exclude_files.count > 0
          podspec += "    p.exclude_files = '#{podspec_exclude_files.uniq.join("','")}'\n"
        end

        if pod.xcconfig.count > 0
          podspec += "    p.xcconfig = #{pod.xcconfig.to_s.gsub("\"", "'")}\n"
        end
        
        podspec += "  end"
        
        podspecs.push(podspec)
      end
      
      cwd = File.dirname(File.expand_path(__FILE__))
      podspec_file = File.read("#{cwd}/templates/build_podspec.template")
      podspec_file.gsub!("%%%podspecs%%%", podspecs.join("\n\n"))
      
      File.write(PodBuilder::basepath("PodBuilder.podspec"), podspec_file)
    end
    
    private

    def self.vendored_framework_path(pod)
      if File.exist?(PodBuilder::basepath(vendored_subspec_framework_path(pod)))
        return vendored_subspec_framework_path(pod)
      elsif File.exist?(PodBuilder::basepath(vendored_spec_framework_path(pod)))
        return vendored_spec_framework_path(pod)
      end

      return nil
    end
    
    def self.vendored_subspec_framework_path(pod)
      return "Rome/#{pod.prebuilt_rel_path}"
    end

    def self.vendored_spec_framework_path(pod)
      return "Rome/#{pod.module_name}.framework"
    end
  end
end