require 'cocoapods'
require 'fileutils'
require 'colored'

require 'pod_builder/podfile'
require 'pod_builder/podfile_item'
require 'pod_builder/analyze'
require 'pod_builder/install'
require 'pod_builder/info'
require 'pod_builder/configuration'
require 'pod_builder/podspec'
require 'pod_builder/licenses'

require 'core_ext/string'

module PodBuilder  
  def self.safe_rm_rf(path)
    unless File.exist?(path)
      return
    end

    current_dir = Dir.pwd

    Dir.chdir(path)

    h = `git rev-parse --show-toplevel`.strip()
    raise "\n\nNo git repository found, can't delete files!\n".red if h.empty?

    FileUtils.rm_rf(path)

    if File.exist?(current_dir)
      Dir.chdir(current_dir)
    else
      Dir.chdir(basepath)
    end
  end
  
  def self.basepath(child = "")
    return "#{Configuration.base_path}/#{child}".gsub("//", "/").gsub(/\/$/, '')
  end
  
  def self.project_path(child = "")
    project = PodBuilder::find_xcodeworkspace
    
    return project ? "#{File.dirname(project)}/#{child}".gsub("//", "/").gsub(/\/$/, '') : nil
  end

  def self.find_xcodeproj
    project_name = File.basename(find_xcodeworkspace, ".*")

    xcodeprojects = Dir.glob("#{home}/**/#{project_name}.xcodeproj").select { |x| 
      folder_in_home = x.gsub(home, "")
      !folder_in_home.include?("/Pods/") && !x.include?(PodBuilder::basepath("Sources")) && !x.include?(basepath) 
    }
    raise "xcodeproj not found!".red if xcodeprojects.count == 0
    raise "Found multiple xcodeproj:\n#{xcodeprojects.join("\n")}".red if xcodeprojects.count > 1

    return xcodeprojects.first
  end

  def self.find_xcodeworkspace
    xcworkspaces = Dir.glob("#{home}/**/#{Configuration.project_name}*.xcworkspace").select { |x| 
      folder_in_home = x.gsub(home, "")
      !folder_in_home.include?("/Pods/") && !x.include?(PodBuilder::basepath("Sources")) && !x.include?(basepath) && !x.include?(".xcodeproj/")
    }
    raise "xcworkspace not found!".red if xcworkspaces.count == 0
    raise "Found multiple xcworkspaces:\n#{xcworkspaces.join("\n")}".red if xcworkspaces.count > 1

    return xcworkspaces.first
  end

  def self.prepare_basepath
    workspace_path = PodBuilder::find_xcodeworkspace
    project_path = PodBuilder::find_xcodeproj
    if workspace_path && project_path
      FileUtils.mkdir_p(basepath("Pods/Target Support Files"))
      FileUtils.cp_r(workspace_path, basepath)   
      FileUtils.cp_r(project_path, basepath)   
      FileUtils.rm_f(basepath("Podfile.lock"))
    end
  end

  def self.clean_basepath
    if path = PodBuilder::find_xcodeproj
      PodBuilder::safe_rm_rf(basepath(File.basename(path)))      
    end
    if path = PodBuilder::find_xcodeworkspace
      PodBuilder::safe_rm_rf(basepath(File.basename(path)))      
    end

    PodBuilder::safe_rm_rf(basepath("Pods"))
  end

  def self.system_swift_version
    swift_version = `swiftc --version | grep -o 'swiftlang-.*\s'`.strip()
    raise "Unsupported swift compiler version, expecting `swiftlang` keyword in `swiftc --version`" if swift_version.length == 0
    return swift_version
  end

  def self.add_lock_file
    lockfile_path = File.join(home, Configuration.lock_filename)

    if File.exist?(lockfile_path)
      if pid = File.read(lockfile_path)
        begin
          if Process.getpgid(pid)
              raise "\n\nAnother PodBuilder pending task is running on this project\n".red    
          end
        rescue
        end
      end  
    end

    File.write(lockfile_path, Process.pid, mode: "w")
  end

  def self.remove_lock_file
    lockfile_path = File.join(home, Configuration.lock_filename)
    if File.exist?(lockfile_path)
      FileUtils.rm(lockfile_path)
    end
  end

  private 
  
  def self.home
    h = `git rev-parse --show-toplevel`.strip()
    raise "\n\nNo git repository found in current folder `#{Dir.pwd}`!\n".red if h.empty?
    return h
  end
end
