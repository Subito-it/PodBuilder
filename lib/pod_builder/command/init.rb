require 'pod_builder/core'

module PodBuilder
  module Command
    class Init
      def self.call
        raise "\n\nAlready initialized\n".red if Configuration.exists

        xcworkspace = Dir.glob("*.xcworkspace")
        raise "\n\nNo xcworkspace found in current folder\n".red if xcworkspace.count == 0
        raise "\n\nToo many xcworkspaces found in current folder\n#{xcworkspace}\n".red if xcworkspace.count > 1

        Configuration.project_name = File.basename(xcworkspace.first, ".*")

        OPTIONS[:prebuild_path] ||= Configuration.base_path

        if File.expand_path(OPTIONS[:prebuild_path]) != OPTIONS[:prebuild_path] # if not absolute
          OPTIONS[:prebuild_path] = File.expand_path(PodBuilder::project_path(OPTIONS[:prebuild_path]))
        end

        FileUtils.mkdir_p(OPTIONS[:prebuild_path])
        FileUtils.mkdir_p("#{OPTIONS[:prebuild_path]}/.pod_builder")
        FileUtils.touch("#{OPTIONS[:prebuild_path]}/.pod_builder/pod_builder")

        write_gitignore
        write_gitattributes

        project_podfile_path = PodBuilder::project_path("Podfile")
        prebuilt_podfile_path = File.join(OPTIONS[:prebuild_path], "Podfile")
        FileUtils.cp(project_podfile_path, prebuilt_podfile_path)

        podfile_content = File.read(prebuilt_podfile_path)

        podfile_content = Podfile.add_configuration_load_block(podfile_content)
        podfile_content = Podfile.add_install_block(podfile_content)
        podfile_content = Podfile.update_path_entries(podfile_content, Init.method(:podfile_path_transform))
        podfile_content = Podfile.update_project_entries(podfile_content, Init.method(:podfile_path_transform))
        podfile_content = Podfile.update_require_entries(podfile_content, Init.method(:podfile_path_transform))

        if podfile_content.include?("/node_modules/react-native/")
          podfile_content = Podfile.prepare_for_react_native(podfile_content)
          update_react_native_podspecs()
        end

        File.write(prebuilt_podfile_path, podfile_content)

        Configuration.write

        update_gemfile

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private

      def self.write_gitignore
        source_path_rel_path = "Sources"
        development_pods_config_rel_path = Configuration.dev_pods_configuration_filename

        git_ignores = ["Pods/",
                       "*.xcworkspace",
                       "*.xcodeproj",
                       "Podfile.lock",
                       Configuration.lldbinit_name,
                       source_path_rel_path,
                       development_pods_config_rel_path]

        if Configuration.react_native_project
          git_ignores.push("build/")
        end

        File.write("#{OPTIONS[:prebuild_path]}/.gitignore", git_ignores.join("\n"))
      end

      def self.write_gitattributes
        git_attributes = ["#{Configuration.prebuilt_info_filename} binary"]

        File.write("#{OPTIONS[:prebuild_path]}/.gitattributes", git_attributes.join("\n"))
      end

      def self.podfile_path_transform(path)
        use_absolute_paths = false
        podfile_path = File.join(OPTIONS[:prebuild_path], "Podfile")
        original_basepath = PodBuilder::project_path

        podfile_base_path = Pathname.new(File.dirname(podfile_path))

        original_path = Pathname.new(File.join(original_basepath, path))
        replace_path = original_path.relative_path_from(podfile_base_path)
        if use_absolute_paths
          replace_path = replace_path.expand_path(podfile_base_path)
        end

        return replace_path
      end

      def self.update_gemfile
        gemfile_path = File.join(PodBuilder::home, "Gemfile")
        unless File.exist?(gemfile_path)
          FileUtils.touch(gemfile_path)
        end

        source_line = "source 'https://rubygems.org'"
        podbuilder_line = "gem 'pod-builder'"

        gemfile = File.read(gemfile_path)

        gemfile_lines = gemfile.split("\n")
        gemfile_lines.select! { |x| !trim_gemfile_line(x).include?(trim_gemfile_line(source_line)) }
        gemfile_lines.select! { |x| !trim_gemfile_line(x).include?(trim_gemfile_line(podbuilder_line)) }

        gemfile_lines.insert(0, source_line)
        gemfile_lines.push(podbuilder_line)

        File.write(gemfile_path, gemfile_lines.join("\n"))

        Dir.chdir(PodBuilder::home) do
          system("bundle")
        end
      end

      def self.trim_gemfile_line(line)
        return line.gsub("\"", "'").gsub(" ", "")
      end

      def self.update_react_native_podspecs
        # React-Core.podspec
        file = "React-Core.podspec"
        paths = Dir.glob("#{PodBuilder::git_rootpath}/node_modules/**/#{file}")
        raise "\n\nUnexpected number of #{file} found\n".red if paths.count != 1

        content = File.read(paths[0])
        expected_header_search_path_prefix = "s.pod_target_xcconfig    = {\n    \"HEADER_SEARCH_PATHS\" => \""
        raise "\n\nExpected header search path entry not found\n".red unless content.include?(expected_header_search_path_prefix)

        content.sub!(expected_header_search_path_prefix, "#{expected_header_search_path_prefix}\\\"$(PODS_ROOT)/Headers/Public/Flipper-Folly\\\" ")
        File.write(paths[0], content)

        # React-CoreModules.podspec
        file = "React-CoreModules.podspec"
        paths = Dir.glob("#{PodBuilder::git_rootpath}/node_modules/**/#{file}")
        raise "\n\nUnexpected number of #{file} found\n".red if paths.count != 1

        content = File.read(paths[0])
        expected_header_search_path_prefix = "\"HEADER_SEARCH_PATHS\" => \""
        raise "\n\nExpected header search path entry not found\n".red unless content.include?(expected_header_search_path_prefix)

        content.sub!(expected_header_search_path_prefix, "#{expected_header_search_path_prefix}\\\"$(PODS_ROOT)/Headers/Public/Flipper-Folly\\\" \\\"$(PODS_ROOT)/../build/generated/ios\\\" ")
        File.write(paths[0], content)
      end
    end
  end
end
