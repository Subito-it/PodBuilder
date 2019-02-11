require 'cfpropertylist'

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

    def self.framework_rel_path(framework_path, podfile_items)
      framework_name = File.basename(framework_path)
      framework_name_no_ext = File.basename(framework_name, File.extname(framework_name))
      if podfile_item = podfile_items.detect { |x| x.module_name == framework_name_no_ext && Configuration.subspecs_to_split.include?(x.name) }
        return "#{podfile_item.prebuilt_rel_path}"
      else
        return framework_name
      end
    end

    def self.add_framework_plist_info(podfile_items)
      swift_version = PodBuilder::system_swift_version
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        filename = File.basename(framework_path, ".*")

        specs = podfile_items.select { |x| x.module_name == filename }
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

          plist.value = CFPropertyList.guess(plist_data)
          plist.save(podbuilder_file, CFPropertyList::List::FORMAT_BINARY)
        else
          raise "Unable to detect item for framework #{filename}.framework. Please open a bug report!"
        end
      end
    end

    def self.cleanup_frameworks(podfile_items)
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        framework_rel_path = framework_rel_path(framework_path, podfile_items)
        dsym_path = framework_rel_path + ".dSYM"

        PodBuilder::safe_rm_rf(PodBuilder::basepath("Rome/#{framework_rel_path}"))
        PodBuilder::safe_rm_rf(PodBuilder::basepath("dSYM/iphoneos/#{dsym_path}"))
        PodBuilder::safe_rm_rf(PodBuilder::basepath("dSYM/iphonesimulator/#{dsym_path}"))
      end
    end

    def self.copy_frameworks(podfile_items)
      Dir.glob("#{Configuration.build_path}/Rome/*.framework") do |framework_path|
        framework_rel_path = framework_rel_path(framework_path, podfile_items)

        destination_path = PodBuilder::basepath("Rome/#{framework_rel_path}")
        FileUtils.mkdir_p(File.dirname(destination_path))
        FileUtils.cp_r(framework_path, destination_path)
      end
    end

    def self.copy_dsyms(podfile_items)
      Dir.glob("#{Configuration.build_path}/dSYM/*iphoneos/**/*.dSYM") do |dsym_path|
        framework_rel_path = framework_rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)
        
        destination_path = PodBuilder::basepath("dSYM/iphoneos/#{File.dirname(framework_rel_path)}") 
        FileUtils.mkdir_p(destination_path)
        FileUtils.cp_r(dsym_path, destination_path)
      end

      Dir.glob("#{Configuration.build_path}/dSYM/*iphonesimulator/**/*.dSYM") do |dsym_path|
        framework_rel_path = framework_rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)

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
