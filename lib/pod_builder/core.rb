require 'cocoapods'
require 'fileutils'
require 'colored'

require 'pod_builder/podfile'
require 'pod_builder/podfile_cp'
require 'pod_builder/podfile_item'
require 'pod_builder/analyze'
require 'pod_builder/analyzer'
require 'pod_builder/install'
require 'pod_builder/info'
require 'pod_builder/configuration'
require 'pod_builder/podspec'
require 'pod_builder/licenses'
require 'pod_builder/actions'

require 'core_ext/string'

module PodBuilder  
  @@xcodeproj_path = nil
  @@xcodeworkspace_path = nil

  def self.git_rootpath
    return `git rev-parse --show-toplevel`.strip()
  end

  def self.safe_rm_rf(path)
    unless File.exist?(path)
      return
    end

    unless File.directory?(path)
      FileUtils.rm(path)

      return 
    end

    current_dir = Dir.pwd

    Dir.chdir(path)

    rootpath = git_rootpath()
    raise "\n\nNo git repository found in '#{path}', can't delete files!\n".red if rootpath.empty? && !path.start_with?(Configuration.build_base_path)

    FileUtils.rm_rf(path)

    if File.exist?(current_dir)
      Dir.chdir(current_dir)
    else
      Dir.chdir(basepath)
    end
  end

  def self.gitignoredfiles
    Dir.chdir(git_rootpath) do
      return `git status --ignored -s | grep "^\!\!" | cut -c4-`.strip().split("\n")
    end
  end
  
  def self.basepath(child = "")
    if child.nil?
      return nil
    end

    return "#{Configuration.base_path}/#{child}".gsub("//", "/").gsub(/\/$/, '')
  end

  def self.prebuiltpath(child = "")
    if child.nil?
      return nil
    end

    path = basepath("Prebuilt")
    if child.length > 0
      path += "/#{child}"
    end

    return path
  end

  def self.buildpath_prebuiltpath(child = "")
    if child.nil?
      return nil
    end

    path = "#{Configuration.build_path}/Prebuilt"
    if child.length > 0
      path += "/#{child}"
    end

    return path
  end

  def self.buildpath_dsympath(child = "")
    if child.nil?
      return nil
    end

    path = "#{Configuration.build_path}/dSYM"
    if child.length > 0
      path += "/#{child}"
    end

    return path
  end

  def self.dsympath(child = "")
    if child.nil?
      return nil
    end

    path = basepath("dSYM")
    if child.length > 0
      path += "/#{child}"
    end

    return path
  end
  
  def self.project_path(child = "")
    project = PodBuilder::find_xcodeworkspace
    
    return project ? "#{File.dirname(project)}/#{child}".gsub("//", "/").gsub(/\/$/, '') : nil
  end

  def self.find_xcodeproj
    unless @@xcodeproj_path.nil?
      return @@xcodeproj_path
    end
    project_name = File.basename(find_xcodeworkspace, ".*")

    xcodeprojects = Dir.glob("#{home}/**/#{project_name}.xcodeproj").select { |x| 
      folder_in_home = x.gsub(home, "")
      !folder_in_home.include?("/Pods/") && !x.include?(PodBuilder::basepath("Sources")) && !x.include?(PodBuilder::basepath + "/") 
    }
    raise "\n\nxcodeproj not found!\n".red if xcodeprojects.count == 0
    raise "\n\nFound multiple xcodeproj:\n#{xcodeprojects.join("\n")}".red if xcodeprojects.count > 1

    @@xcodeproj_path = xcodeprojects.first
    return @@xcodeproj_path
  end

  def self.find_xcodeworkspace
    unless @@xcodeworkspace_path.nil?
      return @@xcodeworkspace_path
    end

    xcworkspaces = Dir.glob("#{home}/**/#{Configuration.project_name}*.xcworkspace").select { |x| 
      folder_in_home = x.gsub(home, "")
      !folder_in_home.include?("/Pods/") && !x.include?(PodBuilder::basepath("Sources")) && !x.include?(PodBuilder::basepath + "/") && !x.include?(".xcodeproj/")
    }
    raise "\n\nxcworkspace not found!\n".red if xcworkspaces.count == 0
    raise "\n\nFound multiple xcworkspaces:\n#{xcworkspaces.join("\n")}".red if xcworkspaces.count > 1

    @@xcodeworkspace_path = xcworkspaces.first
    return @@xcodeworkspace_path
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
    raise "\n\nUnsupported swift compiler version, expecting `swiftlang` keyword in `swiftc --version`\n".red if swift_version.length == 0
    return swift_version
  end

  def self.add_lockfile
    lockfile_path = Configuration.lockfile_path

    if File.exist?(lockfile_path)
      if pid = File.read(lockfile_path)
        begin
          if Process.getpgid(pid)
            if Configuration.deterministic_build    
              raise "\n\nAnother PodBuilder pending task is running\n".red    
            else
              raise "\n\nAnother PodBuilder pending task is running on this project\n".red    
            end
          end
        rescue
        end
      end  
    end

    File.write(lockfile_path, Process.pid, mode: "w")
  end

  def self.remove_lockfile
    lockfile_path = Configuration.lockfile_path

    if File.exist?(lockfile_path)
      FileUtils.rm(lockfile_path)
    end
  end

  private 
  
  def self.home
    rootpath = git_rootpath
    raise "\n\nNo git repository found in current folder `#{Dir.pwd}`!\n".red if rootpath.empty?
    return rootpath
  end
end
