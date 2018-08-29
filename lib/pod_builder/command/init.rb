require 'pod_builder/core'

module PodBuilder
  module Command
    class Init
      def self.call(options)
        raise "\n\nAlready initialized\n".red if Configuration.exists
        raise "\n\nXcode project missing\n".red if PodBuilder::xcodepath.nil?
        
        options[:prebuild_path] ||= Configuration.base_path

        if File.expand_path(options[:prebuild_path]) != options[:prebuild_path] # if not absolute
          options[:prebuild_path] = File.expand_path(PodBuilder::xcodepath(options[:prebuild_path]))
        end

        FileUtils.mkdir_p(options[:prebuild_path])
        FileUtils.mkdir_p("#{options[:prebuild_path]}/.pod_builder")
        FileUtils.touch("#{options[:prebuild_path]}/.pod_builder/pod_builder")
        
        File.write("#{options[:prebuild_path]}/.gitignore", "Pods/\n*.xcodeproj\nSources\n")

        project_podfile_path = PodBuilder::xcodepath("Podfile")
        prebuilt_podfile_path = File.join(options[:prebuild_path], "Podfile")
        FileUtils.cp(project_podfile_path, prebuilt_podfile_path)
        
        add_install_block(prebuilt_podfile_path)

        add_pre_install_actions(project_podfile_path)
        add_post_install_checks(project_podfile_path)

        Configuration.write

        puts "\n\n🎉 done!\n".green
        return true
      end

      private

      def self.add_install_block(podfile_path)
        add(Podfile::PODBUILDER_LOCK_ACTION, "pre_install", podfile_path)
      end

      def self.add_pre_install_actions(podfile_path)
        pre_install_actions = ["Pod::Installer::Xcode::TargetValidator.send(:define_method, :verify_no_duplicate_framework_and_library_names) {}"]
        add(pre_install_actions, "pre_install", podfile_path)
      end

      def self.add_post_install_checks(podfile_path)
        post_install_actions = ["require 'pod_builder/podfile/post_actions'", "PodBuilder::Podfile::remove_target_support_duplicate_entries", "PodBuilder::Podfile::check_target_support_resource_collisions"]
        add(post_install_actions, "post_install", podfile_path)
      end

      def self.add(entries, marker, podfile_path)
        podfile_content = File.read(podfile_path)

        entries.map! { |x| "   #{x}\n"}

        marker_found = false
        podfile_lines = []
        podfile_content.each_line do |line|
          stripped_line = Podfile::strip_line(line)
  
          podfile_lines.push(line)
          if stripped_line.start_with?("#{marker}do|")
            marker_found = true
            podfile_lines.push(entries)
          end
        end

        if !marker_found
          podfile_lines.push("\n#{marker} do |installer|\n")
          podfile_lines.push(entries)
          podfile_lines.push("end\n")
        end

        File.write(podfile_path, podfile_lines.join)
      end
    end
  end
end
