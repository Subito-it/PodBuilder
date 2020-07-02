require 'cfpropertylist'

# The Pod::Target and Pod::Installer::Xcode::PodTargetDependencyInstaller swizzles patch
# the following issues: 
# - https://github.com/CocoaPods/Rome/issues/81
# - https://github.com/leavez/cocoapods-binary/issues/50
begin
  require 'cocoapods/installer/xcode/pods_project_generator/pod_target_dependency_installer.rb'

  class Pod::Specification
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_hash, :from_hash)
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_string, :from_string)

    def self.from_string(*args)
      spec = swz_from_string(*args)

      if overrides = PodBuilder::Configuration.spec_overrides[spec.name]
        overrides.each do |k, v|
          spec.attributes_hash[k] = v
        end
      end

      spec
    end
  end 

  class Pod::Target
    attr_accessor :mock_dynamic_framework

    alias_method :swz_build_type, :build_type

    def build_type
      if mock_dynamic_framework == true
        if defined?(Pod::BuildType) # CocoaPods 1.9 and later
          Pod::BuildType.new(linkage: :dynamic, packaging: :framework)
        elsif defined?(Pod::Target::BuildType) # CocoaPods 1.7, 1.8
          Pod::Target::BuildType.new(linkage: :dynamic, packaging: :framework)
        else
          raise "BuildType not found. Open an issue reporting your CocoaPods version"
        end
      else
        swz_build_type()
      end
    end
  end

  class Pod::Installer::Xcode::PodTargetDependencyInstaller
    alias_method :swz_wire_resource_bundle_targets, :wire_resource_bundle_targets
  
    def wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = pod_target.build_as_static_framework?
      res = swz_wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = false
      return res
    end
  end  
rescue LoadError
  # CocoaPods 1.6.2 or earlier
end

module PodBuilder
  class Install
    def self.podfile(podfile_content, podfile_items, build_configuration)
      PodBuilder::safe_rm_rf(Configuration.build_path)
      FileUtils.mkdir_p(Configuration.build_path)

      # Copy the repo to extract license (and potentially other files in the future)
      podfile_items.select { |x| x.is_development_pod }.each do |podfile_item|
        destination_path = "#{Configuration.build_path}/Pods/#{podfile_item.name}"
        FileUtils.mkdir_p(destination_path)

        if Pathname.new(podfile_item.path).absolute?
          FileUtils.cp_r("#{podfile_item.path}/.", destination_path)
        else 
          FileUtils.cp_r("#{PodBuilder::basepath(podfile_item.path)}/.", destination_path)
        end

        # It is important that CocoaPods compiles the files under Configuration.build_path in order that DWARF
        # debug info reference to this path. Doing otherwise breaks the assumptions that make the `update_lldbinit`
        # command work
        podfile_content.gsub!("'#{podfile_item.path}'", "'#{destination_path}'")
        
        license_files = Dir.glob("#{destination_path}/**/*acknowledgements.plist").each { |f| File.delete(f) }
      end
      
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
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.framework")) do |framework_path|
        filename_ext = File.basename(framework_path)
        filename = File.basename(framework_path, ".*")

        specs = podfile_items.select { |x| x.module_name == filename }
        specs += podfile_items.select { |x| x.vendored_frameworks.map { |x| File.basename(x) }.include?(filename_ext) }
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
          plist_data['original_compile_path'] = Pathname.new(Configuration.build_path).realpath.to_s

          plist.value = CFPropertyList.guess(plist_data)
          plist.save(podbuilder_file, CFPropertyList::List::FORMAT_BINARY)
        else
          raise "Unable to detect item for framework #{filename}.framework. Please open a bug report!"
        end
      end
    end

    def self.cleanup_frameworks(podfile_items)
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.framework")) do |framework_path|
        framework_rel_path = rel_path(framework_path, podfile_items)
        dsym_path = framework_rel_path + ".dSYM"

        PodBuilder::safe_rm_rf(PodBuilder::prebuiltpath(framework_rel_path))
        PodBuilder::safe_rm_rf(PodBuilder::dsympath("iphoneos/#{dsym_path}"))
        PodBuilder::safe_rm_rf(PodBuilder::dsympath("iphonesimulator/#{dsym_path}"))
      end
    end

    def self.copy_frameworks(podfile_items)
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.framework")) do |framework_path|
        framework_rel_path = rel_path(framework_path, podfile_items)

        destination_path = PodBuilder::prebuiltpath(framework_rel_path)
        FileUtils.mkdir_p(File.dirname(destination_path))
        FileUtils.cp_r(framework_path, destination_path)
      end
    end

    def self.copy_libraries(podfile_items)
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.a")) do |library_path|
        library_name = File.basename(library_path)

        # Find vendored libraries in the build folder:
        # This allows to determine which Pod is associated to the vendored_library
        # because there are cases where vendored_libraries are specified with wildcards (*.a)
        # making it impossible to determine the associated Pods when building multiple pods at once
        search_base = "#{Configuration.build_path}/Pods/"
        podfile_items.each do |podfile_item|
          if podfile_item.vendored_framework_path.nil?
            next
          end
          
          podfile_item.vendored_libraries.each do |vendored_item|
            if result = Dir.glob("#{search_base}**/#{vendored_item}").first
              result_path = result.gsub(search_base, "")
              module_name = result_path.split("/").first
              if module_name == podfile_item.module_name
                library_rel_path = rel_path(module_name, podfile_items)
                                
                result_path = result_path.split("/").drop(1).join("/")

                destination_path = PodBuilder::prebuiltpath("#{library_rel_path}/#{result_path}")
                FileUtils.mkdir_p(File.dirname(destination_path))
                FileUtils.cp_r(library_path, destination_path, :remove_destination => true)
              end
            end
          end

          # A pod might depend upon a static library that is shipped with a prebuilt framework
          # which is not added to the Rome folder and podspecs
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

              destination_path = PodBuilder::prebuiltpath("#{library_rel_path}/#{result_path}")
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
        
        destination_path = PodBuilder::dsympath("iphoneos/#{File.dirname(framework_rel_path)}") 
        FileUtils.mkdir_p(destination_path)
        FileUtils.cp_r(dsym_path, destination_path)
      end

      Dir.glob("#{Configuration.build_path}/dSYM/*iphonesimulator/**/*.dSYM") do |dsym_path|
        framework_rel_path = rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)

        destination_path = PodBuilder::dsympath("iphonesimulator/#{File.dirname(framework_rel_path)}") 
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
