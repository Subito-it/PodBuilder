require 'cfpropertylist'


# We swizzle the analyzer to inject spec overrides
class Pod::Specification::Linter::Analyzer
  alias_method :swz_analyze, :analyze

  def analyze(*args)
    spec = consumer.spec
    if overrides = PodBuilder::Configuration.spec_overrides[spec.name]
      overrides.each do |k, v|
        spec.attributes_hash[k] = v
      end
    end

    return swz_analyze
  end
end

module PodBuilder
  class Install
    def self.podfile(podfile_content, podfile_items, build_configuration)
      PodBuilder::safe_rm_rf(Configuration.build_path)
      FileUtils.mkdir_p(Configuration.build_path)
      
      init_git(Configuration.build_path) # this is needed to be able to call safe_rm_rf

      podfile_path = "#{Configuration.build_path}/Podfile"
      File.write(podfile_path, podfile_content)
      Podfile.update_path_entires(podfile_path, true)
      Podfile.update_project_entries(podfile_path, true)

      begin  
        lock_file = "#{Configuration.build_path}/pod_builder.lock"
        FileUtils.touch(lock_file)
  
        install

        add_framework_plist_info(podfile_items)
        cleanup_frameworks(podfile_items)
        copy_frameworks(podfile_items)
        copy_libraries(podfile_items)
        if build_configuration != "debug"
          copy_dsyms(podfile_items)
        end
      rescue Exception => e
        raise e
      ensure
        FileUtils.rm(lock_file)
      end
    end

    private 

    def self.install
      CLAide::Command::PluginManager.load_plugins("cocoapods")

      current_dir = Dir.pwd
      
      Dir.chdir(Configuration.build_path)

      config = Pod::Config.new()
      installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
      installer.repo_update = false
      installer.update = false
      installer.install!  

      Dir.chdir(current_dir)
    end

    def self.rel_path(path, podfile_items)
      name = File.basename(path)
      name_no_ext = File.basename(name, File.extname(name))
      if podfile_item = podfile_items.detect { |x| x.module_name == name_no_ext && Configuration.subspecs_to_split.include?(x.name) }
        return "#{podfile_item.prebuilt_rel_path}"
      else
        return name
      end
    end

    def self.add_framework_plist_info(podfile_items)
      swift_version = PodBuilder::system_swift_version
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        filename_ext = File.basename(framework_path)
        filename = File.basename(framework_path, ".*")

        specs = podfile_items.select { |x| x.module_name == filename }
        specs += podfile_items.select { |x| x.vendored_items.map { |x| File.basename(x) }.include?(filename_ext) }
        if podfile_item = specs.first
          podbuilder_file = File.join(framework_path, Configuration.framework_plist_filename)
          entry = podfile_item.entry(true, false)

          plist = CFPropertyList::List.new
          plist_data = {}
          plist_data['entry'] = entry
          plist_data['is_prebuilt'] = podfile_item.is_prebuilt  
          if Dir.glob(File.join(framework_path, "Headers/*-Swift.h")).count > 0
            plist_data['swift_version'] = swift_version
          end
          subspecs_deps = specs.map(&:dependency_names).flatten
          subspec_self_deps = subspecs_deps.select { |x| x.start_with?("#{podfile_item.root_name}/") }
          plist_data['specs'] = (specs.map(&:name) + subspec_self_deps).uniq
          plist_data['is_static'] = podfile_item.is_static

          plist.value = CFPropertyList.guess(plist_data)
          plist.save(podbuilder_file, CFPropertyList::List::FORMAT_BINARY)
        else
          raise "Unable to detect item for framework #{filename}.framework. Please open a bug report!"
        end
      end
    end

    def self.cleanup_frameworks(podfile_items)
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        framework_rel_path = rel_path(framework_path, podfile_items)
        dsym_path = framework_rel_path + ".dSYM"

        PodBuilder::safe_rm_rf(PodBuilder::basepath("Rome/#{framework_rel_path}"))
        PodBuilder::safe_rm_rf(PodBuilder::basepath("dSYM/iphoneos/#{dsym_path}"))
        PodBuilder::safe_rm_rf(PodBuilder::basepath("dSYM/iphonesimulator/#{dsym_path}"))
      end
    end

    def self.copy_frameworks(podfile_items)
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        framework_rel_path = rel_path(framework_path, podfile_items)

        destination_path = PodBuilder::basepath("Rome/#{framework_rel_path}")
        FileUtils.mkdir_p(File.dirname(destination_path))
        FileUtils.cp_r(framework_path, destination_path)
      end
    end

    def self.copy_libraries(podfile_items)
      Dir.glob("#{Configuration.build_path}/Rome/*.a") do |library_path|
        library_name = File.basename(library_path)

        # Find vendored libraries in the build folder:
        # This allows to determine which Pod is associated to the vendored_library
        # because there are cases where vendored_libraries are specified with wildcards (*.a)
        # making it impossible to determine the associated Pods when building multiple pods at once
        search_base = "#{Configuration.build_path}/Pods/"
        podfile_items.each do |podfile_item|
          podfile_item.vendored_items.each do |vendored_item|
            unless vendored_item.end_with?(".a")
              next
            end
            
            if result = Dir.glob("#{search_base}**/#{vendored_item}").first
              result_path = result.gsub(search_base, "")
              module_name = result_path.split("/").first
              if module_name == podfile_item.module_name
                library_rel_path = rel_path(module_name, podfile_items)
                                
                result_path = result_path.split("/").drop(1).join("/")

                destination_path = PodBuilder::basepath("Rome/#{library_rel_path}/#{result_path}")
                FileUtils.mkdir_p(File.dirname(destination_path))
                FileUtils.cp_r(library_path, destination_path)        
              end
            end
          end

          # A pod might depend upon a static library that is shipped with a prebuilt framework
          # which is not added to the Rome folder and the PodBuilder.podspec
          # 
          # An example is Google-Mobile-Ads-SDK which adds
          # - vendored framework: GooleMobileAds.framework 
          # - vendored library: libGooleMobileAds.a
          # These might be used by another pod (e.g AppNexusSDK/GoogleAdapterThatDependsOnGooglePod)
          podfile_item.libraries.each do |library|            
            if result = Dir.glob("#{search_base}**/lib#{library}.a").first
              result_path = result.gsub(search_base, "")

              library_rel_path = rel_path(podfile_item.module_name, podfile_items)
                                
              result_path = result_path.split("/").drop(1).join("/")

              destination_path = PodBuilder::basepath("Rome/#{library_rel_path}/#{result_path}")
              FileUtils.mkdir_p(File.dirname(destination_path))
              FileUtils.cp_r(library_path, destination_path)        
            end
          end
        end
      end
    end

    def self.copy_dsyms(podfile_items)
      Dir.glob("#{Configuration.build_path}/dSYM/*iphoneos/**/*.dSYM") do |dsym_path|
        framework_rel_path = rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)
        
        destination_path = PodBuilder::basepath("dSYM/iphoneos/#{File.dirname(framework_rel_path)}") 
        FileUtils.mkdir_p(destination_path)
        FileUtils.cp_r(dsym_path, destination_path)
      end

      Dir.glob("#{Configuration.build_path}/dSYM/*iphonesimulator/**/*.dSYM") do |dsym_path|
        framework_rel_path = rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)

        destination_path = PodBuilder::basepath("dSYM/iphonesimulator/#{File.dirname(framework_rel_path)}") 
        FileUtils.mkdir_p(destination_path)
        FileUtils.cp_r(dsym_path, destination_path)
      end
    end

    def self.init_git(path)
      current_dir = Dir.pwd

      Dir.chdir(path)
      system("git init")
      Dir.chdir(current_dir)
    end
  end
end
