require "pod_builder/core"
require "json"

module PodBuilder
  module Command
    class CompileSwiftModules
      def self.call
        Configuration.check_inited

        Podfile.sanity_check()

        puts "Loading Podfile".yellow

        quiet = OPTIONS.fetch(:quiet, false)

        install_update_repo = OPTIONS.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        iphoneos_sdk_path = `xcrun --sdk iphoneos --show-sdk-path`.strip
        sim_sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip

        swiftinterfaces_paths = Dir.glob("#{PodBuilder::git_rootpath}/**/*.framework/**/*.swiftinterface").reject { |t| t.include?(".private.") }
        frameworks_paths = Dir.glob("#{PodBuilder::git_rootpath}/**/*.framework")
        swiftinterfaces_paths = filter_unexpected_pods_locations(swiftinterfaces_paths)
        frameworks_paths = filter_unexpected_pods_locations(frameworks_paths)

        all_buildable_items.uniq(&:root_name).map(&:root_name).each do |name|
          items = all_buildable_items.select { |t| t.root_name == name }
          module_name = items.first.module_name

          vendored_frameworks = items.map(&:vendored_frameworks).flatten

          deps = items.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten
          vendored_frameworks += deps.map(&:vendored_frameworks).flatten
          deps.uniq! { |t| t.root_name }

          swiftinterfaces_and_arch_for_module(module_name, swiftinterfaces_paths).each do |dep_swiftinterface_path, arch|
            swiftmodule_dest = "#{File.dirname(dep_swiftinterface_path)}/#{arch}.swiftmodule"
            if File.exist?(swiftmodule_dest) && !OPTIONS.has_key?(:force_rebuild)
              puts "Swiftmodule exists, skipping #{dep_swiftinterface_path}".magenta if !quiet
              next
            end

            puts "Processing #{dep_swiftinterface_path}".yellow if !quiet

            frameworks_search_paths = []
            deps.each do |dep|
              frameworks_search_paths << framework_path_for_module_name(dep.module_name, arch, swiftinterfaces_paths, frameworks_paths)
            end
            vendored_frameworks.each do |vendored_framework|
              frameworks_search_paths << framework_path_for_module_name(File.basename(vendored_framework, ".*"), arch, swiftinterfaces_paths, frameworks_paths)
            end
            frameworks_search_paths_arg = frameworks_search_paths.compact.map { |t| "-F '#{File.dirname(t)}'" }.join(" ")

            sdk_path = arch.include?("simulator") ? sim_sdk_path : iphoneos_sdk_path
            cmd = "" "swiftc -frontend \
                      -compile-module-from-interface \
                      -enable-library-evolution \
                      -import-underlying-module \
                      -sdk '#{sdk_path}' \
                      -Fsystem '#{sdk_path}/System/Library/Frameworks/' \
                      -module-name #{module_name} \
                      #{frameworks_search_paths_arg} \
                      -o '#{swiftmodule_dest}'  \
                      '#{dep_swiftinterface_path}'
                      " ""

            unless system(cmd)
              puts "Failed generating swiftmodules for #{module_name} and arch #{arch}".red
            end
          end
        end

        puts "\n\n🎉 done!\n".green
        return 0
      end

      def self.swiftinterfaces_and_arch_for_module(module_name, swiftinterfaces_paths)
        swiftinterfaces_paths.select { |t| t.include?("/#{module_name}.xcframework") }.map { |t| [t, File.basename(t, ".*")] }
      end

      def self.framework_path_for_module_name(module_name, arch, swiftinterfaces_paths, frameworks_paths)
        quiet = OPTIONS.fetch(:quiet, false)

        if (path = swiftinterfaces_paths.detect { |t| t.include?("/#{module_name}.framework/Modules/#{module_name}.swiftmodule/#{arch}") }) &&
           (match = path.match(/(.*#{module_name}.framework)/)) && match&.size == 2
          return match[1]
        end

        archs = arch.split("-").reject { |t| ["apple", "ios"].include?(t) }
        frameworks_paths = frameworks_paths.select { |t| t.include?("#{module_name}.framework") }

        frameworks_paths.select! { |t| t.include?("-simulator/") == arch.include?("simulator") }
        frameworks_paths.select! { |t| t.include?("/ios-") } # currently we support only iOS xcframeworks
        frameworks_paths.reject! { |t| t.include?("maccatalyst/") } # currently we do not support catalyst xcframeworks

        frameworks_paths.select! { |t| archs.any? { |u| t.include?(u) } }

        if frameworks_paths.count == 1
          return frameworks_paths[0]
        end

        puts "Failed determining framework for #{module_name}" unless quiet
        return nil
      end

      def self.filter_unexpected_pods_locations(paths)
        # A project might contain multiple /Pods/ folders in subprojects. We should extract only those related to the PodBuilder project
        paths.reject { |t| t.include?("/Pods/") && !t.include?(PodBuilder::project_path) }
      end
    end
  end
end

class Pod::Specification
  public

  def defined_in_folder
    File.dirname(defined_in_file)
  end
end
