require 'pod_builder/core'

module PodBuilder
  module Command
    class Build
      def self.call 
        Configuration.check_inited
        PodBuilder::prepare_basepath

        argument_pods = ARGV.dup

        unless argument_pods.count > 0 
          return -1
        end

        raise "\n\nPlease rename your Xcode installation path removing spaces, current `#{`xcode-select -p`.strip()}`\n".red if `xcode-select -p`.strip().include?(" ")

        Podfile.sanity_check()
        check_not_building_subspecs(argument_pods)

        puts "Loading Podfile".yellow

        install_update_repo = OPTIONS.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)
        prebuilt_items = all_buildable_items.select { |x| x.is_prebuilt }
        buildable_items = all_buildable_items - prebuilt_items

        build_all = argument_pods.first == "*"
        if build_all
          argument_pods = all_buildable_items.map(&:root_name).uniq
        else
          argument_pods = Podfile::resolve_pod_names(argument_pods, all_buildable_items)
          argument_pods.uniq!
        end

        available_argument_pods = argument_pods.select { |x| all_buildable_items.map(&:root_name).include?(x) }     
        (argument_pods - available_argument_pods).each { |x|
          puts "'#{x}' not found, skipping".magenta
        }
        argument_pods = available_argument_pods.uniq
        
        Podfile.restore_podfile_clean(all_buildable_items)

        restore_file_error = Podfile.restore_file_sanity_check
  
        check_pods_exists(argument_pods, all_buildable_items)

        pods_to_build = resolve_pods_to_build(argument_pods, buildable_items)
        buildable_items -= pods_to_build

        argument_pods += pods_to_build.map(&:root_name)
        argument_pods.uniq!

        # We need to split pods to build in 4 groups
        # 1. pods to build in release
        # 2. pods to build in debug
        # 3. pods to build in release as xcframeworks
        # 4. pods to build in debug as xcframeworks

        check_not_building_development_pods(pods_to_build)

        # We need to recursively add dependencies to properly split pods in groups.
        # Example:        
        # 1. PodA has a dep to PodB
        # 2. PodB is marked to be built as xcframework
        # 3. We rebuild PodA only (pods_to_build contains only PodA)
        # 4. We need to add dependencies recursively so that PodB is is added to pods_to_build_release_xcframework
        pods_to_build = pods_to_build.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten.uniq

        pods_to_build_debug = pods_to_build.select { |x| x.build_configuration == "debug" }
        pods_to_build_release = pods_to_build - pods_to_build_debug

        pods_to_build_debug_xcframework = pods_to_build_debug.select { |x| x.build_xcframework }
        pods_to_build_debug -= pods_to_build_debug_xcframework

        pods_to_build_release_xcframework = pods_to_build_release.select { |x| x.build_xcframework }
        pods_to_build_release -= pods_to_build_release_xcframework

        check_dependencies_build_configurations(all_buildable_items)

        # When building mixed framwork/xcframeworks pods xcframeworks should be built last 
        # so that the .xcframework overwrite the .framwork if the same pod needs to be built
        # in both ways. 
        # For example we might have configured to build onlt PodA as xcframework, another pod
        # PodB has a dependency to PodA. When Building PodB, PodA gets rebuilt as .framework
        # but then PodA gets rebuilt again as .xcframework overwriting the .framework.
        podfiles_items = [pods_to_build_debug] + [pods_to_build_release] + [pods_to_build_debug_xcframework] + [pods_to_build_release_xcframework]

        install_using_frameworks = Podfile::install_using_frameworks(analyzer)
        if Configuration.react_native_project
          if install_using_frameworks
            raise "\n\nOnly static library packaging currently supported for react native projects. Please remove 'use_frameworks!' in #{PodBuilder::basepath("Podfile")}\n".red 
          end  
          prepare_defines_modules_override(all_buildable_items)
        else
          unless install_using_frameworks
            raise "\n\nOnly framework packaging currently supported. Please add 'use_frameworks!' at root level (not nested in targets) in #{PodBuilder::basepath("Podfile")}\n".red
          end  
        end
        
        build_catalyst = should_build_catalyst(installer)

        install_result = InstallResult.new
        podfiles_items.reject { |x| x.empty? }.each do |podfile_items|
          build_configuration = podfile_items.map(&:build_configuration).uniq.first

          # We need to recursively find dependencies again because some of the required dependencies might have been moved to a separate group
          # Example:
          # 1. PodA has a dep to PodB
          # 2. PodB is marked to be built as xcframework -> PodB will be added to pods_to_build_release_xcframework and won't be present in
          # pods_to_build_release and therefore build will fail
          podfile_items = podfile_items.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten.uniq
          
          podfile_content = Podfile.from_podfile_items(podfile_items, analyzer, build_configuration, install_using_frameworks, build_catalyst, podfile_items.first.build_xcframework)
          
          install_result += Install.podfile(podfile_content, podfile_items, argument_pods, podfile_items.first.build_configuration)          
          
          FileUtils.rm_f(PodBuilder::basepath("Podfile.lock"))
        end

        install_result.write_prebuilt_info_files

        Clean::prebuilt_items(all_buildable_items)

        Licenses::write(install_result.licenses, all_buildable_items)

        Podspec::generate(all_buildable_items, analyzer, install_using_frameworks)

        builded_pods = podfiles_items.flatten
        
        builded_pods_and_deps = podfiles_items.flatten.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten.uniq
        builded_pods_and_deps.select! { |x| !x.is_prebuilt }
        
        prebuilt_pods_to_install = prebuilt_items.select { |x| argument_pods.include?(x.root_name) }
        Podfile::write_restorable(builded_pods_and_deps + prebuilt_pods_to_install, all_buildable_items, analyzer)     
        if !OPTIONS.has_key?(:skip_prebuild_update)   
          Podfile::write_prebuilt(all_buildable_items, analyzer)
        end

        Podfile::install

        sanity_checks

        if (restore_file_error = restore_file_error) && Configuration.restore_enabled
          puts "\n\n⚠️ Podfile.restore was found invalid and was overwritten. Error:\n #{restore_file_error}".red
        end

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private

      def self.should_build_catalyst(installer)
        build_settings = installer.analysis_result.targets.map { |t| t.user_project.root_object.targets.map { |u| u.build_configuration_list.build_configurations.map { |v| v.build_settings } } }.flatten
        build_catalyst = build_settings.detect { |t| t["SUPPORTS_MACCATALYST"] == "YES" } != nil 
        
        puts "\nTo support Catalyst you should enable 'build_xcframeworks' in PodBuilder.json\n".red if build_catalyst && !Configuration.build_xcframeworks_all

        return build_catalyst
      end

      def self.prepare_defines_modules_override(all_buildable_items)
        all_buildable_items.each do |item|
          unless item.defines_module.nil?
            Pod::PodTarget.modules_override[item.root_name] = item.defines_module
          end
        end
      end

      def self.check_not_building_subspecs(pods_to_build)
        pods_to_build.each do |pod_to_build|
          if pod_to_build.include?("/")
            raise "\n\nCan't build subspec #{pod_to_build} refer to podspec name.\n\nUse `pod_builder build #{pods_to_build.map { |x| x.split("/").first }.uniq.join(" ")}` instead\n\n".red
          end
        end
      end

      def self.check_pods_exists(pods, buildable_items)
        raise "\n\nEmpty Podfile?\n".red if buildable_items.nil?

        buildable_items = buildable_items.map(&:root_name)
        pods.each do |pod|
          raise "\n\nPod `#{pod}` wasn't found in Podfile.\n\nFound:\n#{buildable_items.join("\n")}\n".red if !buildable_items.include?(pod)
        end
      end

      def self.check_dependencies_build_configurations(pods)
        pods.each do |pod|
          pod_dependency_names = pod.dependency_names.select { |x| !pod.has_common_spec(x) }

          remaining_pods = pods - [pod]
          pods_with_common_deps = remaining_pods.select { |x| x.dependency_names.any? { |y| pod_dependency_names.include?(y) && !x.has_common_spec(y) } }
          
          pods_with_unaligned_build_configuration = pods_with_common_deps.select { |x| x.build_configuration != pod.build_configuration }
          pods_with_unaligned_build_configuration.map!(&:name)

          raise "\n\nDependencies of `#{pod.name}` don't have the same build configuration (#{pod.build_configuration}) of `#{pods_with_unaligned_build_configuration.join(",")}`'s dependencies\n".red if pods_with_unaligned_build_configuration.count > 0
        end
      end

      def self.check_not_building_development_pods(pods)
        if (development_pods = pods.select { |x| x.is_development_pod }) && development_pods.count > 0 && (OPTIONS[:allow_warnings].nil?  && Configuration.allow_building_development_pods == false && Configuration.react_native_project == false)
          pod_names = development_pods.map(&:name).join(", ")
          raise "\n\nThe following pods are in development mode: `#{pod_names}`, won't proceed building.\n\nYou can ignore this error by passing the `--allow-warnings` flag to the build command\n".red
        end
      end

      def self.other_subspecs(pods_to_build, buildable_items)
        buildable_subspecs = buildable_items.select { |x| x.is_subspec }
        pods_to_build_subspecs = pods_to_build.select { |x| x.is_subspec }.map(&:root_name)

        buildable_subspecs.select! { |x| pods_to_build_subspecs.include?(x.root_name) }

        return buildable_subspecs - pods_to_build
      end

      def self.sanity_checks
        lines = File.read(PodBuilder::project_path("Podfile")).split("\n")
        stripped_lines = lines.map { |x| Podfile.strip_line(x) }.select { |x| !x.start_with?("#")}

        expected_stripped = Podfile::PRE_INSTALL_ACTIONS.map { |x| Podfile.strip_line(x) }

        if !expected_stripped.all? { |x| stripped_lines.include?(x) }
          warn_message = "PodBuilder's pre install actions missing from application Podfile!\n"
          if OPTIONS[:allow_warnings]
            puts "\n\n#{warn_message}".yellow
          else
            raise "\n\n#{warn_message}\n".red
          end
        end
      end

      def self.resolve_pods_to_build(argument_pods, buildable_items)
        pods_to_build = []
        
        pods_to_build = buildable_items.select { |x| argument_pods.include?(x.root_name) }
        pods_to_build += other_subspecs(pods_to_build, buildable_items)

        # Build all pods that depend on the those that were explictly passed by the user
        dependencies = []
        buildable_items.each do |pod|
          if !(pod.dependencies(buildable_items) & pods_to_build).empty?
            dependencies.push(pod)
          end
        end
        log = dependencies.reject { |t| pods_to_build.map(&:root_name).include?(t.root_name) }.map(&:root_name)
        puts "Adding inverse dependencies: #{log.join(", ")}".blue

        pods_to_build += dependencies

        return pods_to_build.uniq
      end      
    end
  end
end
