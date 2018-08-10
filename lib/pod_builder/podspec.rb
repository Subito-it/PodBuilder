module PodBuilder
  class Podspec
    def self.generate      
      buildable_items = Podfile.podfile_items_at(PodBuilder::basepath("Podfile"))
      buildable_items.select! { |x| x.is_prebuilt == false }
      
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