require 'pod_builder/core'

module PodBuilder
  module Command
    class Init
      def self.call(options)
        raise "\n\nAlready initialized\n".red if Configuration.exists
        raise "\n\nXcode workspace not found\n".red if PodBuilder::project_path.nil?
        
        options[:prebuild_path] ||= Configuration.base_path

        if File.expand_path(options[:prebuild_path]) != options[:prebuild_path] # if not absolute
          options[:prebuild_path] = File.expand_path(PodBuilder::project_path(options[:prebuild_path]))
        end

        FileUtils.mkdir_p(options[:prebuild_path])
        FileUtils.mkdir_p("#{options[:prebuild_path]}/.pod_builder")
        FileUtils.touch("#{options[:prebuild_path]}/.pod_builder/pod_builder")

        source_path_rel_path = "Sources"
        development_pods_config_rel_path = Configuration.dev_pods_configuration_filename
        
        File.write("#{options[:prebuild_path]}/.gitignore", "Pods/\n*.xcodeproj\n#{source_path_rel_path}\n#{development_pods_config_rel_path}\n")

        project_podfile_path = PodBuilder::project_path("Podfile")
        prebuilt_podfile_path = File.join(options[:prebuild_path], "Podfile")
        FileUtils.cp(project_podfile_path, prebuilt_podfile_path)
        
        Podfile.add_install_block(prebuilt_podfile_path)
        Podfile.update_path_entires(prebuilt_podfile_path, false, PodBuilder::project_path(""))
        Podfile.update_project_entries(prebuilt_podfile_path, false, PodBuilder::project_path(""))

        Configuration.write

        puts "\n\n🎉 done!\n".green
        return true
      end
    end
  end
end
