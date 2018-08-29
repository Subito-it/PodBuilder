require 'pod_builder/cocoapods/analyzer'

module PodBuilder
  class Podfile
    PODBUILDER_LOCK_ACTION = ["raise \"\\n🚨  Do not launch 'pod install' manually, use `pod_builder` instead!\\n\" if !File.exist?('pod_builder.lock')"].freeze
    PRE_INSTALL_ACTIONS = ["Pod::Installer::Xcode::TargetValidator.send(:define_method, :verify_no_duplicate_framework_and_library_names) {}"].freeze
    POST_INSTALL_ACTIONS = ["require 'pod_builder/podfile/post_actions'", "PodBuilder::Podfile::remove_target_support_duplicate_entries", "PodBuilder::Podfile::check_target_support_resource_collisions"].freeze

    def self.from_podfile_items(items, analyzer)
      raise "no items" unless items.count > 0

      sources = analyzer.sources
      
      cwd = File.dirname(File.expand_path(__FILE__))
      podfile = File.read("#{cwd}/templates/build_podfile.template")
      
      podfile.sub!("%%%sources%%%", sources.map { |x| "source '#{x.url}'" }.join("\n"))

      build_configurations = items.map(&:build_configuration).uniq
      raise "Found different build configurations in #{items}" if build_configurations.count != 1
      podfile.sub!("%%%build_configuration%%%", build_configurations.first.capitalize)

      build_settings = Configuration.build_settings
      podfile_build_settings = ""
      
      pod_dependencies = {}

      items.each do |item|
        item_build_settings = Configuration.build_settings_overrides[item.name] || {}
        build_settings['SWIFT_VERSION'] = item_build_settings["SWIFT_VERSION"] || project_swift_version(analyzer)
        if item.is_static
          # https://forums.developer.apple.com/thread/17921
          build_settings['CLANG_ENABLE_MODULE_DEBUGGING'] = "NO"
        end

        item_build_settings.each do |k, v|
          build_settings[k] = v
        end

        podfile_build_settings += "set_build_settings(\"#{item.root_name}\", #{build_settings.to_s}, installer)\n  "

        dependency_names = item.dependency_names.map { |x|
          if x.split("/").first == item.root_name
            next nil # remove dependency to parent spec
          end
          if overridded_module_name = Configuration.spec_overrides.fetch(x, {})["module_name"]
            next overridded_module_name
          end
        }.compact
  
        if dependency_names.count > 0
          pod_dependencies[item.root_name] = dependency_names
        end
      end

      podfile.sub!("%%%build_settings%%%", podfile_build_settings)

      podfile.sub!("%%%build_system%%%", Configuration.build_system)

      podfile.sub!("%%%pods%%%", "\"#{items.map(&:name).join('", "')}\"")
      
      podfile.sub!("%%%pods_dependencies%%%", pod_dependencies.to_s)
      
      podfile.sub!("%%%targets%%%", items.map(&:entry).join("\n  "))

      return podfile
    end

    def self.write_restorable(updated_pods, podfile_items, analyzer)
      podfile_items = podfile_items.dup
      podfile_restore_path = PodBuilder::basepath("Podfile.restore")
      podfile_path = PodBuilder::basepath("Podfile")

      if File.exist?(podfile_restore_path)
        restore_podfile_items = podfile_items_at(podfile_restore_path)

        podfile_items.map! { |podfile_item|
          if updated_pod = updated_pods.detect { |x| x.name == podfile_item.name } then
            updated_pod
          elsif restored_pod = restore_podfile_items.detect { |x| x.name == podfile_item.name }
            restored_pod
          else
            podfile_item
          end
        }
      end

      result_targets = analyzer.result.targets.map(&:name) 
      podfile_content = analyzer.podfile.sources.map { |x| "source '#{x}'" }
      podfile_content += ["", "use_frameworks!", ""]

      # multiple platforms not (yet) supported
      # https://github.com/CocoaPods/Rome/issues/37
      platform = analyzer.result.targets.first.platform
      podfile_content += ["platform :#{platform.name}, '#{platform.deployment_target.version}'", ""]

      analyzer.result.specs_by_target.each do |target, specifications|
        unless result_targets.select { |x| x.end_with?(target.name) }.count > 0
          next
        end

        podfile_content.push("target '#{target.name}' do")

        specifications.each do |spec|
          item = podfile_items.detect { |x| x.name == spec.name }
          podfile_content.push("\t#{item.entry}")
        end

        podfile_content.push("end\n")
      end

      File.write(podfile_restore_path, podfile_content.join("\n"))
    end

    def self.update_prebuilt(updated_pods, podfile_items, analyzer)
      project_podfile_path = PodBuilder::xcodepath("Podfile")

      podfile_content = File.read(project_podfile_path)

      stripped_prebuilt_entries = (updated_pods + podfile_items).map(&:prebuilt_entry).map { |x| strip_line(x) }
      podfile_items_name = podfile_items.map(&:name)

      destination_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)

        if pod_name = pod_definition_in(line, true)
          if updated_pod = updated_pods.detect { |x| x.name == pod_name }
            destination_lines.push("  #{updated_pod.prebuilt_entry}\n")
            destination_lines.push("  # #{updated_pod.entry(false)}\n")
            next
          elsif !podfile_items_name.include?(pod_name) && !stripped_prebuilt_entries.include?(stripped_line)
            next
          end
        end

        destination_lines.push(line)
      end

      # remove adiacent duplicated entries
      destination_lines = destination_lines.chunk { |x| x }.map(&:first)

      podfile_content = destination_lines.join
      File.write(project_podfile_path, podfile_content)
    end

    def self.deintegrate_install
      current_dir = Dir.pwd

      Dir.chdir(PodBuilder::xcodepath)
      system("pod deintegrate; pod install;")
      Dir.chdir(current_dir)
    end

    def self.strip_line(line)
      stripped_line = line.dup
      return stripped_line.gsub("\"", "'").gsub(" ", "").gsub("\n", "")
    end

    private

    def self.pod_definition_in(line, include_commented)
      stripped_line = strip_line(line)
      matches = stripped_line.match(/(^pod')(.*?)(')/)
      
      if matches&.size == 4 && (include_commented || !stripped_line.start_with?("#"))
        return matches[2]
      else
        return nil
      end
    end

    def self.project_swift_version(analyzer)
      swift_versions = analyzer.result.target_inspections.values.map { |x| x.target_definition.swift_version }.uniq

      raise "Found different Swift versions in targets. Expecting one, got `#{swift_versions}`" if swift_versions.count != 1

      return swift_versions.first
    end

    def self.podfile_items_at(podfile_path)
      raise "Expecting basepath folder!" if !File.exist?(PodBuilder::basepath("Podfile"))

      if File.basename(podfile_path) != "Podfile"
        File.rename(PodBuilder::basepath("Podfile"), PodBuilder::basepath("Podfile.tmp"))
        FileUtils.cp(podfile_path, PodBuilder::basepath("Podfile"))
      end

      current_dir = Dir.pwd
      Dir.chdir(File.dirname(podfile_path))

      buildable_items = []
      begin
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath)
      
        podfile_items = Analyze.podfile_items(installer, analyzer)
        buildable_items = podfile_items.select { |item| item.is_prebuilt == false }   
      rescue Exception => e
        raise e
      ensure
        Dir.chdir(current_dir)
      
        if File.basename(podfile_path) != "Podfile"
          File.rename(PodBuilder::basepath("Podfile.tmp"), PodBuilder::basepath("Podfile"))
        end  
      end

      return buildable_items
    end
  end
end
