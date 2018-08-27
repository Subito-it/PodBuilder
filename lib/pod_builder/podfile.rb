require 'pod_builder/cocoapods/analyzer'

module PodBuilder
  class Podfile

    PRE_INSTALL_ACTIONS = ["raise \"\\n🚨  Do not launch 'pod install' manually, use `pod_builder` instead!\\n\" if !File.exist?('pod_builder.lock')"]

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
      items.each do |item|
        item_build_settings = Configuration.build_settings_overrides[item.name] || {}
        build_settings['SWIFT_VERSION'] = item_build_settings["SWIFT_VERSION"] || project_swift_version(analyzer)

        item_build_settings.each do |k, v|
          build_settings[k] = v
        end

        podfile_build_settings += "set_build_settings(\"#{item.root_name}\", #{build_settings.to_s}, installer)\n  "
      end

      podfile.sub!("%%%build_settings%%%", podfile_build_settings)

      podfile.sub!("%%%build_system%%%", Configuration.build_system)

      podfile.sub!("%%%pods%%%", "\"#{items.map(&:name).join('", "')}\"")
      
      podfile.sub!("%%%dependencies%%%", "\"#{items.map(&:dependency_names).flatten.uniq.join("\",\"")}\"")
      
      podfile.sub!("%%%targets%%%", items.map(&:entry).join("\n  "))

      return podfile
    end

    def self.write_restorable(updated_pods, podfile_items, analyzer)
      podfile_items = podfile_items.dup
      podfile_restore_path = PodBuilder::basepath("Podfile.restore")
      podfile_path = PodBuilder::basepath("Podfile")

      if File.exist?(podfile_restore_path)
        podfile_content = File.read(podfile_restore_path)

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
      else
        podfile_content = File.read(podfile_path)
      end
      
      current_target = nil
      destination_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)
        if current_target.nil?
          destination_lines.push(line)

          if current_target = target_definition_in(line, false)
            target_pods, target_dependencies = analyzer.pods_and_deps_in_target(current_target, podfile_items)

            # dependecies should be listed first
            current_target_pods = (target_dependencies + target_pods).uniq

            # There should be at most one subspecs per target
            # Taking just one subspec is enough to pin to the correct version
            current_target_pods = current_target_pods.sort_by(&:name).uniq(&:root_name)

            current_target_pods.each { |x| destination_lines.push("  #{x.entry}\n") }
          end
        else          
          if stripped_line == "end"
            destination_lines.push(line)
            current_target = nil
          end
        end
      end

      podfile_content = destination_lines.join
      File.write(podfile_restore_path, podfile_content)
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

    def self.target_definition_in(line, include_commented)
      stripped_line = strip_line(line)
      matches = stripped_line.match(/(^target')(.*?)(')/)
      
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
