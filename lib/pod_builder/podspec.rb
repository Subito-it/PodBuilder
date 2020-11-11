# This file contains the logic that generates the .podspec files that are placed
# along to the prebuild frameworks under PodBuilder/Prebuilt

module PodBuilder
  class Podspec
    def self.generate(all_buildable_items, analyzer, install_using_frameworks)  
      unless all_buildable_items.count > 0
        return
      end
      
      puts "Generating PodBuilder's local podspec".yellow
                  
      platform = analyzer.instance_variable_get("@result").targets.first.platform
      generate_podspec_from(all_buildable_items, platform, install_using_frameworks)
    end
    
    private

    def self.generate_spec_keys_for(item, name, all_buildable_items, install_using_frameworks)
      podspec = ""
      valid = false

      slash_count = name.count("/") + 1
      indentation = "    " * slash_count
      spec_var = "p#{slash_count}"

      if spec_var == "p1" && item.default_subspecs.count > 0
        podspec += "#{indentation}#{spec_var}.default_subspecs = '#{item.default_subspecs.join("', '")}'\n"
      end

      if item.name == name
        if_exists = lambda { |t| File.exist?(PodBuilder::prebuiltpath("#{item.root_name}/#{t}") || "") }

        vendored_frameworks = item.vendored_frameworks 
        if item.default_subspecs.reject { |t| "#{item.root_name}/#{t}" == item.name }.count == 0 && install_using_frameworks
          vendored_frameworks += ["#{item.module_name}.framework", "#{item.module_name}.xcframework"].select(&if_exists)
        end

        existing_vendored_frameworks = vendored_frameworks.select(&if_exists)
        existing_vendored_frameworks_basename = vendored_frameworks.map { |t| File.basename(t) }.select(&if_exists)
        vendored_frameworks = (existing_vendored_frameworks + existing_vendored_frameworks_basename).uniq

        vendored_libraries = item.vendored_libraries
        if install_using_frameworks
          existing_vendored_libraries = vendored_libraries.map { |t| "#{item.module_name}/#{t}" }.select(&if_exists)
          existing_vendored_libraries_basename = vendored_libraries.map { |t| File.basename(t) }.select(&if_exists)
          vendored_libraries = (existing_vendored_libraries + existing_vendored_libraries_basename).uniq        

          # .a are static libraries and should not be included again in the podspec to prevent duplicated symbols (in the app and in the prebuilt framework)
          vendored_libraries.reject! { |t| t.end_with?(".a") }

          public_headers = []
          resources = []
          exclude_files = []
          vendored_frameworks.each do |vendored_framework|
            binary_path = Dir.glob(PodBuilder::prebuiltpath("#{item.root_name}/#{vendored_framework}/**/#{File.basename(vendored_framework, ".*")}")).first

            next if binary_path.nil?

            is_static = `file '#{binary_path}'`.include?("current ar archive")
            if is_static
              parent_folder = File.expand_path("#{binary_path}/..")
              rel_path = Pathname.new(parent_folder).relative_path_from(Pathname.new(PodBuilder::prebuiltpath(item.root_name))).to_s
              
              resources.push("#{rel_path}/*.{nib,bundle,xcasset,strings,png,jpg,tif,tiff,otf,ttf,ttc,plist,json,caf,wav,p12,momd}")
              exclude_files.push("#{rel_path}/Info.plist")
            end
          end
        else          
          public_headers = Dir.glob(PodBuilder::prebuiltpath("#{item.root_name}/#{item.root_name}/Headers/**/*.h"))
          vendored_libraries +=  ["#{item.root_name}/lib#{item.root_name}.a"]
          vendored_libraries = vendored_libraries.select(&if_exists)
           
          resources = ["#{item.root_name}/*.{nib,bundle,xcasset,strings,png,jpg,tif,tiff,otf,ttf,ttc,plist,json,caf,wav,p12,momd}"]

          exclude_files = ["*.modulemap"]
          unless item.swift_version.nil?
            exclude_files += ["Swift Compatibility Header/*", "*.swiftmodule"]
          end
          exclude_files.map! { |t| "#{item.root_name}/#{t}" }
        end

        entries = lambda { |spec_key, spec_value| 
          key = "#{indentation}#{spec_var}.#{spec_key}"
          joined_values = spec_value.map { |t| "#{t}" }.uniq.sort.join("', '")
          "#{key} = '#{joined_values}'\n" 
        }
          
        if vendored_frameworks.count > 0
          podspec += entries.call("vendored_frameworks", vendored_frameworks)
        end      
        if vendored_libraries.count > 0
          podspec += entries.call("vendored_libraries", vendored_libraries)
        end
        if item.frameworks.count > 0
          podspec += entries.call("frameworks", item.frameworks)
        end
        if item.libraries.count > 0
          podspec += entries.call("libraries", item.libraries)
        end
        if resources.count > 0
          podspec += entries.call("resources", resources)
        end
        if exclude_files.count > 0
          podspec += entries.call("exclude_files", exclude_files)
        end
        if public_headers.count > 0
          podspec += "#{indentation}#{spec_var}.public_header_files = '#{item.root_name}/Headers/**/*.h'\n"
        end
        if !item.header_dir.nil? && !install_using_frameworks
          podspec += "#{indentation}#{spec_var}.header_dir = '#{item.header_dir}'\n"
          podspec += "#{indentation}#{spec_var}.header_mappings_dir = '#{item.root_name}/Headers/#{item.header_dir}'\n"
        end

        if item.xcconfig.keys.count > 0
          xcconfig = Hash.new
          item.xcconfig.each do |k, v|
            unless v != "$(inherited)"
              xcconfig[k] = item.xcconfig[k]
              next
            end
            unless k == "OTHER_LDFLAGS"
              next # For the time being limit to OTHER_LDFLAGS key
            end
  
            if podspec_values = item.xcconfig[k]
              podspec_values_arr = podspec_values.split(" ")
              podspec_values_arr.push(v)
              v = podspec_values_arr.join(" ")          
            end
            
            xcconfig[k] = item.xcconfig[k]
          end
  
          if xcconfig.keys.count > 0 
            podspec += "#{indentation}#{spec_var}.xcconfig = #{xcconfig.to_s}\n"
          end
        end
        if !install_using_frameworks && spec_var == "p1" && vendored_libraries.map { |t| File.basename(t) }.include?("lib#{item.root_name}.a" )
          module_path_files = Dir.glob(PodBuilder.prebuiltpath("#{item.root_name}/**/#{item.root_name}.modulemap"))
          raise "\n\nToo many module maps found for #{item.root_name}".red if module_path_files.count > 1

          rel_path = Pathname.new(PodBuilder::prebuiltpath).relative_path_from(Pathname.new(PodBuilder::project_path("Pods"))).to_s
          prebuilt_root_var = "#{item.root_name.upcase.gsub("-", "_")}_PREBUILT_ROOT"

          static_cfg = Hash.new
          if module_path_file = module_path_files.first
            module_map_rel = module_path_file.gsub(PodBuilder::prebuiltpath("#{item.root_name}/#{item.root_name}/"), "")
            static_cfg = { "SWIFT_INCLUDE_PATHS" => "$(inherited) \"$(#{prebuilt_root_var})/#{item.root_name}/#{item.root_name}\"",
                          "OTHER_CFLAGS" => "$(inherited) -fmodule-map-file=\"$(#{prebuilt_root_var})/#{item.root_name}/#{item.root_name}/#{module_map_rel}\"",
                          "OTHER_SWIFT_FLAGS" => "$(inherited) -Xcc -fmodule-map-file=\"$(#{prebuilt_root_var})/#{item.root_name}/#{item.root_name}/#{module_map_rel}\""
                          }            
          end
          static_cfg[prebuilt_root_var] = "$(PODS_ROOT)/#{rel_path}"

          podspec += "#{indentation}#{spec_var}.xcconfig = #{static_cfg.to_s}\n"
          # This seems to be a viable workaround to https://github.com/CocoaPods/CocoaPods/issues/9559 and https://github.com/CocoaPods/CocoaPods/issues/8454
          podspec += "#{indentation}#{spec_var}.user_target_xcconfig = { \"OTHER_LDFLAGS\" => \"$(inherited) -L\\\"$(#{prebuilt_root_var})/#{item.root_name}/#{item.root_name}\\\" -l\\\"#{item.root_name}\\\"\" }\n"
        end
  
        deps = item.dependency_names.sort
        if name == item.root_name
          deps.reject! { |t| t.split("/").first == item.root_name }
        end

        deps.reject! { |t| t == item.name }
        all_buildable_items_name = all_buildable_items.map(&:name)
        deps.select! { |t| all_buildable_items_name.include?(t) }
  
        if deps.count > 0
          if podspec.count("\n") > 1
            podspec += "\n"
          end
          deps.each do |dependency|
            podspec += "#{indentation}#{spec_var}.dependency '#{dependency}'\n"
          end
        end

        valid = valid || (install_using_frameworks ? vendored_frameworks.count > 0 : vendored_libraries.count > 0)
      end

      subspec_base = name.split("/").first(slash_count).join("/")
      subspec_items = all_buildable_items.select { |t| t.name.start_with?("#{subspec_base}/") }

      subspec_names = subspec_items.map { |t| t.name.split("/").drop(slash_count).join("/") }
      subspec_names.map! { |t| "#{subspec_base}/#{t}" }

      subspec_names.each do |subspec|
        subspec_item = all_buildable_items.detect { |t| t.name == subspec } || item

        if podspec.length > 0
          podspec += "\n"
        end
          
        subspec_keys, subspec_valid = generate_spec_keys_for(subspec_item, subspec, all_buildable_items, install_using_frameworks) 
        valid = valid || subspec_valid

        if subspec_keys.length > 0
          podspec += "#{indentation}#{spec_var}.subspec '#{subspec.split("/").last}' do |p#{slash_count + 1}|\n"
          podspec += subspec_keys
          podspec += "#{indentation}end\n"
        end
      end
    
      return podspec, valid
    end

    def self.generate_podspec_from(all_buildable_items, platform, install_using_frameworks)
      prebuilt_podspec_path = all_buildable_items.map(&:prebuilt_podspec_path)
      prebuilt_podspec_path.each do |path|
        if File.exist?(path)
          FileUtils.rm(path)
        end
      end

      all_buildable_items.each do |item|  
        if item.is_prebuilt
          next
        end

        if item.name != item.root_name
          if all_buildable_items.map(&:name).include?(item.root_name)
            next # will process root spec, skip subspecs
          end
        end
        if File.exist?(item.prebuilt_podspec_path)
          next # skip if podspec was already generated
        end

        podspec = "Pod::Spec.new do |p1|\n"

        podspec += "    p1.name             = '#{item.root_name}'\n"
        podspec += "    p1.version          = '#{item.version}'\n"
        podspec += "    p1.summary          = '#{item.summary.gsub("'", "\\'")}'\n"
        podspec += "    p1.homepage         = '#{item.homepage}'\n"
        podspec += "    p1.author           = 'PodBuilder'\n"
        podspec += "    p1.source           = { 'git' => '#{item.source['git']}'}\n"
        podspec += "    p1.license          = { :type => '#{item.license}' }\n"

        podspec += "\n"
        podspec += "    p1.#{platform.safe_string_name.downcase}.deployment_target  = '#{platform.deployment_target.version}'\n"
        podspec += "\n"

        main_keys, valid = generate_spec_keys_for(item, item.root_name, all_buildable_items, install_using_frameworks)
        if !valid
          next
        end

        podspec += main_keys
        podspec += "end"

        spec_path = item.prebuilt_podspec_path
        if File.directory?(File.dirname(spec_path))
          File.write(spec_path, podspec)
        else
          message = "Prebuilt podspec destination not found for #{File.basename(spec_path)}".red
          if ENV['DEBUGGING']
            puts message
          else
            raise message
          end
        end
      end
    end
  end
end