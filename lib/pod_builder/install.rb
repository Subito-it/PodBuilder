
module PodBuilder
  class Install
    def self.podfile(podfile_content, podfile_items, build_configuration)
      PodBuilder::safe_rm_rf(Configuration.build_path)
      FileUtils.mkdir_p(Configuration.build_path)
      
      init_git(Configuration.build_path) # this is needed to be able to call safe_rm_rf

      File.write("#{Configuration.build_path}/Podfile", podfile_content)

      begin  
        lock_file = "#{Configuration.build_path}/pod_builder.lock"
        FileUtils.touch(lock_file)
  
        install
        
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
      if podfile_item = podfile_items.detect { |x| x.module_name == framework_name_no_ext && Configuration.subspecs_to_split.include?(x) }
        return "#{podfile_item.prebuilt_rel_path}"
      else
        return framework_name
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
      Dir.glob("#{Configuration.build_path}/build/*iphoneos/**/*.dSYM") do |dsym_path|
        framework_rel_path = framework_rel_path(dsym_path.gsub(File.extname(dsym_path), ""), podfile_items)
        
        destination_path = PodBuilder::basepath("dSYM/iphoneos/#{File.dirname(framework_rel_path)}") 
        FileUtils.mkdir_p(destination_path)
        FileUtils.cp_r(dsym_path, destination_path)
      end

      Dir.glob("#{Configuration.build_path}/build/*iphonesimulator/**/*.dSYM") do |dsym_path|
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
