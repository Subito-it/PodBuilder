require "json"

module PodBuilder
  class Podfile
    PODBUILDER_LOCK_ACTION = ["raise \"\\n🚨  Do not launch 'pod install' manually, use `pod_builder` instead!\\n\" if !File.exist?('pod_builder.lock')"].freeze

    def self.from_podfile_items(items, analyzer, build_configuration, install_using_frameworks, build_catalyst, build_xcframeworks)
      raise "\n\nno items\n".red unless items.count > 0

      # Xcode 14 requires a development team to be specified for the compilation to succeed
      development_team = Configuration::development_team
      if development_team.empty?
        project_path = "#{PodBuilder.project_path}/#{Configuration::project_name}.xcodeproj"
        development_team = `grep -rh 'DEVELOPMENT_TEAM' '#{project_path}' | uniq`.strip
        development_team_match = development_team.match(/DEVELOPMENT_TEAM = (.+);/)
        if development_team.split("\n").count != 1 || development_team_match&.size != 2
          raise "\n\nFailed getting 'DEVELOPMENT_TEAM' build setting, please add your development team to #{PodBuilder::basepath(Configuration.configuration_filename)} as per documentation".red
        end
        development_team = development_team_match[1]
      end

      sources = analyzer.sources

      cwd = File.dirname(File.expand_path(__FILE__))
      podfile = File.read("#{cwd}/templates/build_podfile.template")

      platform = analyzer.instance_variable_get("@result").targets.first.platform

      podfile.sub!("%%%use_frameworks%%%", install_using_frameworks ? "use_frameworks!" : "use_modular_headers!")
      podfile.sub!("%%%uses_frameworks%%%", install_using_frameworks ? "true" : "false")
      podfile.sub!("%%%build_xcframeworks%%%", build_xcframeworks ? "true" : "false")
      podfile.sub!("%%%build_catalyst%%%", build_catalyst ? "true" : "false")

      podfile.sub!("%%%platform_name%%%", platform.name.to_s)
      podfile.sub!("%%%deployment_version%%%", platform.deployment_target.version)

      podfile.sub!("%%%sources%%%", sources.map { |x| "source '#{x.url}'" }.join("\n"))

      podfile.sub!("%%%build_configuration%%%", build_configuration.capitalize)
      podfile.sub!("%%%keep_swiftmodules%%%", Configuration.keep_swiftmodules ? "true" : "false")

      podfile.sub!("%%%development_team%%%", development_team)

      podfile_build_settings = ""

      pod_dependencies = {}

      items.each do |item|
        build_settings = Configuration.build_settings.dup

        item_build_settings = Configuration.build_settings_overrides[item.name].dup || {}

        # These settings need to be set as is to properly build frameworks
        build_settings["SWIFT_COMPILATION_MODE"] = "wholemodule"
        build_settings["ONLY_ACTIVE_ARCH"] = "NO"
        build_settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"

        # https://thi.imhttps://thi.im/posts/swift-serialize-debugging-options/
        build_settings["SWIFT_SERIALIZE_DEBUGGING_OPTIONS"] = "NO"

        if Configuration.react_native_project && item.name.include?("Folly")
          build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "9.0" # https://github.com/facebook/flipper/issues/834#issuecomment-899725463
        else
          build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = platform.deployment_target.version # Fix compilation warnings on Xcode 12
        end

        # Ignore deprecation warnings
        build_settings["GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS"] = "NO"

        # Improve compile speed
        build_settings["COMPILER_INDEX_STORE_ENABLE"] = "NO"
        build_settings["SWIFT_INDEX_STORE_ENABLE"] = "NO"
        build_settings["MTL_ENABLE_INDEX_STORE"] = "NO"

        if Configuration.build_system == "Legacy"
          build_settings["BUILD_LIBRARY_FOR_DISTRIBUTION"] = "NO"
        elsif Configuration.library_evolution_support || item.build_xcframework
          build_settings["BUILD_LIBRARY_FOR_DISTRIBUTION"] = "YES"
        end

        build_settings["SWIFT_VERSION"] = item_build_settings["SWIFT_VERSION"] || item.swift_version || project_swift_version(analyzer)

        if build_settings["ENABLE_BITCODE"] == "YES"
          build_settings["BITCODE_GENERATION_MODE"] = "bitcode"
        end

        # Don't store .pcm info in binary, see https://forums.swift.org/t/swift-behavior-of-gmodules-and-dsyms/23211/3
        build_settings["CLANG_ENABLE_MODULE_DEBUGGING"] = "NO"
        other_swift_flags_override = " $(inherited) -Xfrontend -no-clang-module-breadcrumbs -Xfrontend -no-serialize-debugging-options"
        other_c_flags_override = " $(inherited)"

        if Configuration.generate_coverage
          other_swift_flags_override += " -profile-coverage-mapping -profile-generate"
          other_c_flags_override += " -fprofile-instr-generate -fcoverage-mapping"
        end

        item_build_settings.each do |k, v|
          # Do not allow to override above settings which are mandatory for a correct compilation
          if build_settings[k].nil?
            build_settings[k] = v
          end
        end

        # All the below settings should be merged with global (Configuration.build_settings) or per pod build_settings (Configuration.build_settings_overrides)
        build_settings["OTHER_SWIFT_FLAGS"] = build_settings.fetch("OTHER_SWIFT_FLAGS", "") + other_swift_flags_override
        build_settings["OTHER_CFLAGS"] = build_settings.fetch("OTHER_CFLAGS", "") + other_c_flags_override

        podfile_build_settings += "set_build_settings(\"#{item.root_name}\", #{build_settings.to_s}, installer)\n  "

        dependency_names = item.dependency_names.map { |x|
          if x.split("/").first == item.root_name
            next nil # remove dependency to parent spec
          end
          if overridded_module_name = Configuration.spec_overrides.fetch(x, {})["module_name"] # this might no longer be needed after
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
      unless Configuration.restore_enabled && (podfile_items.count + updated_pods.count) > 0
        return
      end

      puts "Writing Restore Podfile".yellow

      podfile_items = podfile_items.dup
      podfile_restore_path = PodBuilder::basepath("Podfile.restore")
      podfile_path = PodBuilder::basepath("Podfile")

      if File.exist?(podfile_restore_path)
        restore_podfile_items = podfile_items_at(podfile_restore_path, include_prebuilt = true)

        podfile_items.map! { |podfile_item|
          if updated_pod = updated_pods.detect { |x| x.name == podfile_item.name }
            updated_pod
          elsif updated_pods.any? { |x| podfile_item.root_name == x.root_name } == false && # podfile_item shouldn't be among those being updated (including root specification)
                restored_pod = restore_podfile_items.detect { |x| x.name == podfile_item.name }
            restored_pod
          else
            podfile_item
          end
        }
      end

      result_targets = analyzer.instance_variable_get("@result").targets.map(&:name)
      podfile_content = ["# Autogenerated by PodBuilder (https://github.com/Subito-it/PodBuilder)", "# Please don't modify this file", "\n"]
      podfile_content += analyzer.podfile.sources.map { |x| "source '#{x}'" }
      podfile_content += ["", "use_frameworks!", ""]

      # multiple platforms not (yet) supported
      # https://github.com/CocoaPods/Rome/issues/37
      platform = analyzer.instance_variable_get("@result").targets.first.platform
      podfile_content += ["platform :#{platform.name}, '#{platform.deployment_target.version}'", ""]

      analyzer.instance_variable_get("@result").specs_by_target.each do |target, specifications|
        target_name = target.name.to_s

        unless result_targets.select { |x| x.end_with?(target_name) }.count > 0
          next
        end

        podfile_content.push("target '#{target_name}' do")

        if project_path = target.user_project_path
          podfile_content.push("\tproject '#{project_path}'")
        end

        specifications.each do |spec|
          item = podfile_items.detect { |x| x.name == spec.name }
          if podfile_items.map(&:name).include?(spec.name)
            podfile_content.push("\t#{item.entry}")
          end
        end

        podfile_content.push("end\n")
      end

      File.write(podfile_restore_path, podfile_content.join("\n"))
    end

    def self.write_prebuilt(all_buildable_items, analyzer)
      if Configuration.react_native_project
        return write_prebuilt_react_native(all_buildable_items, analyzer)
      end

      puts "Updating Application Podfile".yellow

      explicit_deps = analyzer.explicit_pods()
      explicit_deps.map! { |t| all_buildable_items.detect { |x| x.name == t.name } }
      explicit_deps.uniq!
      podbuilder_podfile_path = PodBuilder::basepath("Podfile")
      rel_path = Pathname.new(podbuilder_podfile_path).relative_path_from(Pathname.new(PodBuilder::project_path)).to_s

      podfile_content = File.read(podbuilder_podfile_path)

      exclude_lines = Podfile::PODBUILDER_LOCK_ACTION.map { |x| strip_line(x) }

      prebuilt_lines = ["# Autogenerated by PodBuilder (https://github.com/Subito-it/PodBuilder)\n", "# Any change to this file should be done on #{rel_path}\n", "\n"]
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)
        if exclude_lines.include?(stripped_line)
          next
        end

        if pod_name = pod_definition_in(line, true)
          if podfile_item = all_buildable_items.detect { |x| x.name == pod_name }
            marker = podfile_item.prebuilt_marker()

            non_explicit_dependencies = podfile_item.recursive_dependencies(all_buildable_items) - explicit_deps
            non_explicit_dependencies_root_names = non_explicit_dependencies.map(&:root_name).uniq.filter { |t| t != podfile_item.root_name }
            non_explicit_dependencies = non_explicit_dependencies_root_names.map { |x|
              if item = all_buildable_items.detect { |t| x == t.name }
                item
              else
                item = all_buildable_items.detect { |t| x == t.root_name }
              end
            }.compact

            non_explicit_dependencies.each do |dep|
              dep_item = all_buildable_items.detect { |x| x.name == dep.name }

              if File.exist?(dep_item.prebuilt_podspec_path) && !dep_item.is_prebuilt
                pod_name = dep_item.prebuilt_entry(false, false)
                prebuilt_lines.push("#{line.detect_indentation}#{pod_name}#{marker}\n")
              end

              explicit_deps.push(dep)
            end

            if File.exist?(podfile_item.prebuilt_podspec_path) && !podfile_item.is_prebuilt
              prebuilt_lines.push("#{line.detect_indentation}#{podfile_item.prebuilt_entry}\n")
              next
            end
          end
        end

        prebuilt_lines.push(line)
      end

      podfile_content = prebuilt_lines.join

      podfile_content = Podfile.update_path_entries(podfile_content, Podfile.method(:podfile_path_transform))
      podfile_content = Podfile.update_project_entries(podfile_content, Podfile.method(:podfile_path_transform))
      podfile_content = Podfile.update_require_entries(podfile_content, Podfile.method(:podfile_path_transform))

      project_podfile_path = PodBuilder::project_path("Podfile")
      File.write(project_podfile_path, podfile_content)
    end

    def self.write_prebuilt_react_native(all_buildable_items, analyzer)
      puts "Updating Application Podfile".yellow

      podbuilder_podfile_path = PodBuilder::basepath("Podfile")
      rel_path = Pathname.new(podbuilder_podfile_path).relative_path_from(Pathname.new(PodBuilder::project_path)).to_s

      podfile_content = ["# Autogenerated by PodBuilder (https://github.com/Subito-it/PodBuilder)\n", "# Any change to this file should be done on #{rel_path}\n", "\n"].join
      podfile_content += analyzer.podfile.pb_to_s(all_buildable_items)

      podfile_content = Podfile.update_path_entries(podfile_content, PodfileCP.method(:podfile_path_transform))
      podfile_content = Podfile.update_project_entries(podfile_content, Podfile.method(:podfile_path_transform))
      podfile_content = Podfile.update_require_entries(podfile_content, Podfile.method(:podfile_path_transform))

      project_podfile_path = PodBuilder::project_path("Podfile")
      File.write(project_podfile_path, podfile_content)
    end

    def self.install
      puts "Running pod install".yellow

      Dir.chdir(PodBuilder::project_path) do
        bundler_prefix = Configuration.use_bundler ? "bundle exec " : ""

        if Configuration.react_native_project
          system("#{bundler_prefix}pod deintegrate;")
        end

        system("#{bundler_prefix}pod install;")
      end
    end

    def self.strip_line(line)
      stripped_line = line.strip
      return stripped_line.gsub("\"", "'").gsub(" ", "").gsub("\t", "").gsub("\n", "")
    end

    def self.pod_definition_in(line, include_commented)
      stripped_line = strip_line(line)
      matches = stripped_line.match(/(^pod')(.*?)(')/)

      if matches&.size == 4 && (include_commented || !stripped_line.start_with?("#"))
        return matches[2]
      else
        return nil
      end
    end

    def self.restore_podfile_clean(pod_items)
      unless Configuration.restore_enabled
        return
      end

      # remove pods that are no longer listed in pod_items
      podfile_restore_path = PodBuilder::basepath("Podfile.restore")
      unless File.exist?(podfile_restore_path)
        return
      end

      restore_content = File.read(podfile_restore_path)

      cleaned_lines = []
      restore_content.each_line do |line|
        if pod_name = pod_definition_in(line, false)
          if pod_items.map(&:name).include?(pod_name)
            cleaned_lines.push(line)
          end
        else
          cleaned_lines.push(line)
        end
      end

      File.write(podfile_restore_path, cleaned_lines.join)
    end

    def self.restore_file_sanity_check
      unless Configuration.restore_enabled
        return nil
      end

      puts "Checking Podfile.restore".yellow

      podfile_restore_path = PodBuilder::basepath("Podfile.restore")
      unless File.exist?(podfile_restore_path)
        return
      end

      error = nil

      begin
        File.rename(PodBuilder::basepath("Podfile"), PodBuilder::basepath("Podfile.tmp2"))
        File.rename(podfile_restore_path, PodBuilder::basepath("Podfile"))

        Analyze.installer_at(PodBuilder::basepath, false)
      rescue Exception => e
        error = e.to_s
      ensure
        File.rename(PodBuilder::basepath("Podfile"), podfile_restore_path)
        File.rename(PodBuilder::basepath("Podfile.tmp2"), PodBuilder::basepath("Podfile"))
      end

      if !error.nil?
        FileUtils.rm(podfile_restore_path)
      end

      return error
    end

    def self.sanity_check
      podfile_path = PodBuilder::basepath("Podfile")
      unless File.exist?(podfile_path)
        return
      end

      content = File.read(podfile_path)

      content.each_line do |line|
        stripped_line = strip_line(line)
        unless !stripped_line.start_with?("#")
          next
        end

        if stripped_line.match(/(pod')(.*?)(')/) != nil
          starting_def_found = stripped_line.start_with?("def") && (line.match("\s*def\s") != nil)
          raise "\n\nUnsupported single line def/pod. `def` and `pod` shouldn't be on the same line, please modify the following line:\n#{line}\n".red if starting_def_found
        end
      end

      unless content.include?("PodBuilder::Configuration::load")
        raise "\n\nUnsupported PodBuilder/Podfile found!\n\nStarting from version 5.x Podfile should contain the following lines:\nrequire 'pod_builder/core'\nPodBuilder::Configuration::load\n\nPlease manually add them to the top of your Podfile\n".red
      end
    end

    def self.resolve_pod_names(names, all_buildable_items)
      resolved_names = []

      names.each do |name|
        if item = all_buildable_items.detect { |t| t.root_name.downcase == name.downcase }
          resolved_names.push(item.root_name)
        end
      end

      return resolved_names.uniq
    end

    def self.resolve_pod_names_from_podfile(names)
      resolved_names = []

      # resolve potentially wrong pod name case
      podfile_path = PodBuilder::basepath("Podfile")
      content = File.read(podfile_path)

      current_section = ""
      content.each_line do |line|
        matches = line.gsub("\"", "'").match(/pod '(.*?)'/)
        if matches&.size == 2
          if resolved_name = names.detect { |t| matches[1].split("/").first.downcase == t.downcase }
            resolved_names.push(matches[1].split("/").first)
          end
        end
      end

      resolved_names.uniq
    end

    def self.install_using_frameworks(analyzer)
      target_settings = analyzer.podfile.target_definition_list.map(&:uses_frameworks?).uniq
      if target_settings.count == 1
        return target_settings.first
      elsif target_settings.count > 1
        raise "\n\n'use_frameworks!' should be declared only once at Podfile root level (not nested in targets)\n".red
      else
        raise "\n\nFailed detecting use_frameworks!\n".red
      end

      return true
    end

    private

    def self.podfile_path_transform(path)
      use_absolute_paths = false
      podfile_path = PodBuilder::project_path("Podfile")
      original_basepath = PodBuilder::basepath

      podfile_base_path = Pathname.new(File.dirname(podfile_path))

      original_path = Pathname.new(File.join(original_basepath, path))
      replace_path = original_path.relative_path_from(podfile_base_path)
      if use_absolute_paths
        replace_path = replace_path.expand_path(podfile_base_path)
      end

      return replace_path
    end

    def self.indentation_from_string(content)
      lines = content.split("\n").select { |x| !x.empty? }

      if lines.count > 2
        lines[0..-2].each_with_index do |current_line, index|
          next_line = lines[index + 1]
          next_line_first_char = next_line.chars.first
          current_doesnt_begin_with_whitespace = current_line[/\A\S*/] != nil

          if current_doesnt_begin_with_whitespace && [" ", "\t"].include?(next_line_first_char)
            return next_line[/\A\s*/]
          end
        end
      end

      return "  "
    end

    def self.project_swift_version(analyzer)
      swift_versions = analyzer.instance_variable_get("@result").targets.map { |x| x.target_definition.swift_version }.compact.uniq

      raise "\n\nFound different Swift versions in targets. Expecting one, got `#{swift_versions}`\n".red if swift_versions.count > 1

      return swift_versions.first || PodBuilder::system_swift_version
    end

    def self.podfile_items_at(podfile_path, include_prebuilt = false)
      raise "\n\nExpecting basepath folder!\n".red if !File.exist?(PodBuilder::basepath("Podfile"))

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
        buildable_items = podfile_items.select { |item| include_prebuilt || !item.is_prebuilt }
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

    def self.add_install_block(podfile_content)
      return add(PODBUILDER_LOCK_ACTION, "pre_install", podfile_content)
    end

    def self.add_configuration_load_block(podfile_content)
      unless podfile_content.include?("require 'pod_builder/core")
        podfile_content = "require 'pod_builder/core'\nPodBuilder::Configuration::load\n\n" + podfile_content
      end

      return podfile_content
    end

    def self.add(entries, marker, podfile_content)
      file_indentation = indentation_from_string(podfile_content)

      entries = entries.map { |x| "#{file_indentation}#{x}\n" }

      marker_found = false
      podfile_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)

        podfile_lines.push(line)
        if stripped_line.start_with?("#{marker}do|")
          marker_found = true
          podfile_lines.push(entries)
        end
      end

      if !marker_found
        if podfile_lines.last.strip.length > 0
          podfile_lines.push("\n")
        end
        podfile_lines.push("\n#{marker} do |installer|\n")
        podfile_lines.push(entries)
        podfile_lines.push("end\n")
      end

      return podfile_lines.join
    end

    def self.update_path_entries(podfile_content, path_transform)
      regex = "(\s*pod\s*['|\"])(.*?)(['|\"])(.*?):(path|podspec)(\s*=>\s*['|\"])(.*?)(['|\"])"

      podfile_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)
        matches = line.match(/#{regex}/)

        if matches&.size == 9 && !stripped_line.start_with?("#")
          pod_name = matches[2]
          path = matches[7]

          is_absolute = ["~", "/"].include?(path[0])
          unless !PodBuilder::prebuiltpath.end_with?(path) && !is_absolute
            podfile_lines.push(line)
            next
          end

          replace_path = path_transform.call(path)

          updated_path_line = line.gsub(/#{regex}/, '\1\2\3\4:\5\6' + replace_path.to_s + '\8\9')
          podfile_lines.push(updated_path_line)
        else
          podfile_lines.push(line)
        end
      end

      return podfile_lines.join
    end

    def self.update_project_entries(podfile_content, path_transform)
      regex = "(\s*project\s*['|\"])(.*?)(['|\"])"

      podfile_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)
        matches = line.match(/#{regex}/)

        if matches&.size == 4 && !stripped_line.start_with?("#")
          path = matches[2]

          is_absolute = ["~", "/"].include?(path[0])
          unless !is_absolute
            podfile_lines.push(line)
            next
          end

          replace_path = path_transform.call(path)

          updated_path_line = line.gsub(/#{regex}/, '\1' + replace_path.to_s + '\3\4')
          podfile_lines.push(updated_path_line)
        else
          podfile_lines.push(line)
        end
      end

      return podfile_lines.join
    end

    def self.update_require_entries(podfile_content, path_transform)
      regex = "(\s*require_relative\s*['|\"])(.*?)(['|\"])"

      podfile_lines = []
      podfile_content.each_line do |line|
        stripped_line = strip_line(line)
        matches = line.match(/#{regex}/)

        if matches&.size == 4 && !stripped_line.start_with?("#")
          path = matches[2]

          file_exists = [path, "#{path}.rb"].any? { |t| File.exist?(File.expand_path(t)) }

          is_absolute = ["~", "/"].include?(path[0])
          if is_absolute || !file_exists
            podfile_lines.push(line)
            next
          end

          replace_path = path_transform.call(path)

          updated_path_line = line.gsub(/#{regex}/, '\1' + replace_path.to_s + '\3\4')
          podfile_lines.push(updated_path_line)
        else
          podfile_lines.push(line)
        end
      end

      return podfile_lines.join
    end

    def self.prepare_for_react_native_write_pb_configuration(podfile_content)
      base = File.expand_path(File.join(PodBuilder::project_path, ".."))
      bin_js = Dir.glob("#{base}/node_modules/@react-native-community/cli/build/bin.js")

      raise "\n\nReact native cli bin_js not found! Did you run yarn install?\n".red unless bin_js.count == 1
      bin_js = bin_js.first

      config_dest_path = PodBuilder::basepath("rn_config.json")

      raise "\n\nFailed generating react native configuration file\n".red unless system("node '#{bin_js}' config > #{config_dest_path}")

      content = File.read(config_dest_path)

      content.gsub!(PodBuilder::project_path, "..")
      content.gsub!(File.expand_path(PodBuilder::project_path("..")), "../..")

      json = JSON.parse(content)
      begin
        json["project"]["ios"]["sourceDir"] = "./"
        json["project"]["ios"]["podfile"] = "./"
      rescue => exception
        raise "\n\nFailed updating react native configuration json\n".red
      end

      File.write(config_dest_path, JSON.pretty_generate(json))

      return "rn_config = JSON.load(File.read(\"rn_config.json\")) # pb added\n\n" + podfile_content
    end

    def self.prepare_for_react_native_rn_pods_file(podfile_content)
      use_react_native_open_found = false
      enable_hermes = false
      indentation = ""

      lines = []
      podfile_content.each_line do |line|
        if line.include?("use_react_native!(")
          use_react_native_open_found = true

          matches = line.match(/(\s*)/)
          unless matches&.size == 2
            return podfile_content
          end
          indentation = matches[1]
        end

        if use_react_native_open_found
          if line.gsub(" ", "").include?(":hermes_enabled=>true")
            enable_hermes = true
          end
          lines.push("#{indentation}# #{line.strip} # pb removed\n")

          if line.strip.end_with?(")")
            use_react_native_open_found = false
            lines.push("#{indentation}use_react_native!(:path => rn_config[\"reactNativePath\"], :hermes_enabled => #{enable_hermes ? "true" : "false"}) # pb added\n")
          end
        else
          lines.push(line)
        end
      end

      return lines.join
    end

    def self.prepare_for_react_native_native_modules_file(podfile_content)
      lines = []
      podfile_content.each_line do |line|
        if line.include?("use_native_modules!")
          matches = line.match(/(\s*)/)
          unless matches&.size == 2
            return podfile_content
          end

          indentation = matches[1]
          lines.push("#{indentation}use_native_modules!(rn_config) # pb added\n")
          lines.push("#{indentation}# #{line.strip} # pb removed\n")
        else
          lines.push(line)
        end
      end

      return lines.join
    end

    def self.prepare_for_react_native(podfile_content)
      original_podfile_content = podfile_content.dup

      podfile_content = prepare_for_react_native_write_pb_configuration(podfile_content)
      content = prepare_for_react_native_rn_pods_file(podfile_content)
      if content == podfile_content
        return original_podfile_content
      end
      podfile_content = content
      content = prepare_for_react_native_native_modules_file(podfile_content)
      if content == podfile_content
        return original_podfile_content
      end
      podfile_content = content

      Configuration.build_using_repo_paths = true
      Configuration.react_native_project = true

      return podfile_content
    end

    def self.prepare_react_native_compilation_workarounds(podfile_content)
      podfile_content += "" "

def prepare_rn_react_codegen
  # Beginning with version 0.68.0 react native project compilation relies on some autogenerated files
  # that are added to the React-Codegen target
  source_path = \"#{PodBuilder::project_path}/build/generated/ios/.\"
  destination_path = \"#{PodBuilder::basepath}/build/generated/ios\"
  FileUtils.cp_r(source_path, destination_path)
end

def prepare_rn_compilation_libevent
  path = \"Pods/libevent/include/event.h\"
  replace(path, \"#include <evutil.h>\", \"// #include <evutil.h>\")
end

def prepare_rn_flipper_module_redefinition
  module_maps = [\"Pods/Target Support Files/Flipper-Fmt/Flipper-Fmt.modulemap\", \"Pods/Target Support Files/fmt/fmt.modulemap\"]
  if module_maps.all? { |t| File.exist?(t) }
    commented_module = \"/* \" + File.read(module_maps[0]) + \" */\"
    File.write(module_maps[0], commented_module)
  end
end

def replace(path, find, replace)
  if File.exist?(path)
    content = File.read(path).gsub(find, replace)
    File.write(path, content)
  end
end  
" ""

      pre_install = "" "
  require 'json'

  pods_path = \"#{PodBuilder::project_path}/Pods\"
  j = JSON.parse(File.read(\"\#{pods_path}/Local Podspecs/FBReactNativeSpec.podspec.json\"))

  output_files = j.dig(\"script_phases\", \"output_files\")

  script_lines = j.dig(\"script_phases\", \"script\").split(\"\\n\")
  script_lines.insert(0, \"export SCRIPT_OUTPUT_FILE_0=\\\"\#{output_files[0]}\\\"\")
  script_lines.insert(0, \"export DERIVED_FILE_DIR=/tmp\")
  script_lines.insert(0, \"export PODS_TARGET_SRCROOT=\\\"#{PodBuilder::project_path}/../node_modules/react-native/React/FBReactNativeSpec\\\"\")
  script_lines.insert(0, \"export PODS_ROOT=\\\"\#{pods_path}\\\"\")

  Dir.chdir(pods_path) do
    cmd = script_lines.reject(&:blank?).join(\";\\n\")
    system(cmd)
  end
    " ""

      post_install = "" "
  prepare_rn_compilation_libevent()
  prepare_rn_flipper_module_redefinition()
  prepare_rn_react_codegen()

  installer.pods_project.targets.each do |target|
      target.build_configurations.each do |config|
          if target.name == 'React-Codegen'
            config.build_settings['HEADER_SEARCH_PATHS'] = config.build_settings.fetch('HEADER_SEARCH_PATHS', []) + ['$(inherited)', '${PODS_ROOT}/Flipper-Folly', '${PODS_ROOT}/React-Core/ReactCommon', '$(PODS_ROOT)/React-Core/ReactCommon/react/renderer/graphics/platform/cxx', '$(PODS_ROOT)/React-Codegen/build/generated/ios']
          end
          if target.name == 'React-Core'
            config.build_settings['HEADER_SEARCH_PATHS'] = config.build_settings.fetch('HEADER_SEARCH_PATHS', []) + ['$(inherited)', '${PODS_ROOT}/Flipper-Folly']
          end
          if target.name == 'React-CoreModules'
            config.build_settings['HEADER_SEARCH_PATHS'] = config.build_settings.fetch('HEADER_SEARCH_PATHS', []) + ['$(inherited)', '${PODS_ROOT}/Flipper-Folly', '$(PODS_ROOT)/../build/generated/ios']
          end
      end
  end
        " ""

      podfile_content.gsub!("pre_install do |installer|", "pre_install do |installer|\n" + "#{pre_install}\n")
      podfile_content.gsub!("post_install do |installer|", "post_install do |installer|\n" + "#{post_install}\n")

      return podfile_content
    end
  end
end
